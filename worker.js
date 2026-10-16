/**
 * iodef-relay-worker.js  --  set-and-forget domain guard for zurai02.is-a.dev
 *
 * What it does
 *   1. Receives CAA `iodef` violation reports (POST) and relays them to Discord.
 *   2. Every cron run, checks the website over HTTPS plus the DNS records that
 *      keep mail and certificates working (MX, SPF, DMARC, CAA).
 *   3. Alerts ONCE when something breaks, reminds you daily while it stays
 *      broken, and tells you when it recovers.
 *   4. Posts a weekly heartbeat. If the heartbeat ever stops appearing, the
 *      monitor itself is broken -- that is your dead-man's switch.
 *
 * Setup (one time)
 *   - Secret   DISCORD_WEBHOOK_URL   (Settings -> Variables and Secrets, Production)
 *   - KV       Create a KV namespace, then Settings -> Bindings -> add it with the
 *              variable name  STATE.  Optional but strongly recommended: without it
 *              the Worker still runs, but alerts on every failed run, and there is
 *              no recovery notice, no heartbeat and no report rate limit.
 *   - Cron     Settings -> Triggers -> Cron Triggers -> 0 * * * *  (hourly, UTC)
 *   - CAA      { "flags": 0, "tag": "iodef", "value": "<this Worker's hostname>" }
 *
 * The first cron run after setup posts a "Monitor started" message listing every
 * check as OK or failing, which doubles as a configuration test. If a check fails
 * only because it does not match your setup (for example SPF lives elsewhere),
 * delete that line from CHECKS below.
 *
 * Design notes
 *   - Checks only alert after FAILURES_BEFORE_ALERT consecutive failed runs, so a
 *     one-off network blip never pages you.
 *   - If a Discord delivery fails, state is NOT advanced, so the alert is retried
 *     on the next run instead of being lost.
 *   - State is written only when it changes, which keeps KV writes near zero in
 *     normal operation (the free plan allows 1,000 writes per day).
 *   - Inbound bodies are read as a stream with a hard byte cap, so oversized
 *     payloads are rejected without being buffered.
 *   - Time spent awaiting fetch()/setTimeout does not count as Workers CPU time.
 *   - Workers cannot read certificate details, so this detects "broken now", not
 *     "expires soon". GitHub Pages renews Let's Encrypt certificates on its own.
 */

// ---------- Configuration ----------
const SITE_URL = 'https://zurai02.is-a.dev/';
const DOMAIN = 'zurai02.is-a.dev';

const MAX_BODY_BYTES = 8_000;
const MAX_REPORTS_PER_HOUR = 20;

const DISCORD_TIMEOUT_MS = 5_000;
const DISCORD_MAX_RETRIES = 2;
const DISCORD_DEFAULT_RETRY_MS = 1_000;
const DISCORD_MAX_RETRY_MS = 5_000;
const DISCORD_FIELD_LIMIT = 1_000;

const CHECK_TIMEOUT_MS = 10_000;
const SITE_RETRY_DELAY_MS = 2_000;
const FAILURES_BEFORE_ALERT = 2;
const REMINDER_INTERVAL_MS = 24 * 60 * 60 * 1000;
const HEARTBEAT_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000;
const STATE_KEY = 'monitor-state';

const COLORS = {
  iodef: 0xe67e22,
  down: 0xe74c3c,
  reminder: 0xe67e22,
  recovered: 0x2ecc71,
  heartbeat: 0x3498db,
  error: 0x95a5a6,
};

const DNS_TYPES = { MX: 15, TXT: 16, CAA: 257 };

// ---------- Small helpers ----------
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const clip = (text, max = DISCORD_FIELD_LIMIT) =>
  text.length > max ? `${text.slice(0, max - 16)}\n... (truncated)` : text;

const relativeTime = (ms) => `<t:${Math.floor(ms / 1000)}:R>`;

async function fetchWithTimeout(url, init, timeoutMs) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeoutId);
  }
}

// ---------- Discord delivery ----------
function embed({ title, color, fields, footer = 'iodef-relay-worker' }) {
  return {
    title,
    color,
    fields: fields.map(({ name, value, inline = false }) => ({
      name,
      value: clip(String(value) || '-'),
      inline,
    })),
    footer: { text: footer },
    timestamp: new Date().toISOString(),
  };
}

// allowed_mentions.parse = [] guarantees nothing in a report can ping anyone.
const discordPayload = (embeds) => ({ embeds, allowed_mentions: { parse: [] } });

async function attemptDiscordPost(webhookUrl, body) {
  try {
    const response = await fetchWithTimeout(
      webhookUrl,
      { method: 'POST', headers: { 'Content-Type': 'application/json' }, body },
      DISCORD_TIMEOUT_MS,
    );
    await response.body?.cancel().catch(() => {});
    if (response.ok) return { ok: true };

    const seconds = Number(response.headers.get('retry-after'));
    const waitMs =
      response.status === 429 && seconds > 0
        ? Math.min(seconds * 1000, DISCORD_MAX_RETRY_MS)
        : DISCORD_DEFAULT_RETRY_MS;
    return { ok: false, waitMs };
  } catch {
    return { ok: false, waitMs: DISCORD_DEFAULT_RETRY_MS };
  }
}

async function postToDiscord(webhookUrl, payload) {
  const body = JSON.stringify(payload); // serialised once, reused on retries
  for (let attempt = 0; ; attempt += 1) {
    const result = await attemptDiscordPost(webhookUrl, body);
    if (result.ok) return true;
    if (attempt >= DISCORD_MAX_RETRIES) return false;
    await sleep(result.waitMs);
  }
}

// ---------- Inbound iodef reports ----------
function buildReportPayload({ sourceIp, contentType, body }) {
  // Neutralise backtick fences so a report can't break out of the code block.
  const safeBody = body.replaceAll('```', "'''");
  return discordPayload([
    embed({
      title: 'CAA iodef report received',
      color: COLORS.iodef,
      fields: [
        { name: 'Source IP', value: sourceIp, inline: true },
        { name: 'Content-Type', value: contentType, inline: true },
        { name: 'Report body', value: `\`\`\`\n${clip(safeBody, DISCORD_FIELD_LIMIT - 10)}\n\`\`\`` },
      ],
    }),
  ]);
}

/**
 * Reads request.body as a stream and stops the instant the byte cap is
 * crossed, so a client that lies about (or omits) Content-Length can't make
 * the Worker buffer an oversized payload.
 */
async function readBodyWithLimit(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) return { overflow: false, body: '' };

  const decoder = new TextDecoder();
  let total = 0;
  let text = '';

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;

    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return { overflow: true, body: '' };
    }
    text += decoder.decode(value, { stream: true });
  }

  text += decoder.decode();
  return { overflow: false, body: text };
}

// Approximate hourly cap so a flood of POSTs can't spam your Discord channel.
async function isRateLimited(kv, now) {
  if (!kv) return false;
  try {
    const key = `rate:${now.toISOString().slice(0, 13)}`;
    const count = Number((await kv.get(key)) ?? '0');
    if (count >= MAX_REPORTS_PER_HOUR) return true;
    await kv.put(key, String(count + 1), { expirationTtl: 2 * 60 * 60 });
    return false;
  } catch (err) {
    console.error('Rate-limit KV error (allowing request):', err);
    return false;
  }
}

async function handleRequest(request, env, ctx) {
  // ctx is unused: the Discord call is awaited so the status code reflects
  // whether delivery actually succeeded.
  if (request.method === 'GET' || request.method === 'HEAD') {
    return new Response('iodef-relay-worker: alive', { status: 200 });
  }
  if (request.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }
  if (!env.DISCORD_WEBHOOK_URL) {
    return new Response('Server not configured', { status: 500 });
  }

  if (await isRateLimited(env.STATE, new Date())) {
    return new Response('Too many reports', { status: 429, headers: { 'Retry-After': '3600' } });
  }

  const declaredLength = Number(request.headers.get('content-length') ?? '0');
  if (declaredLength > MAX_BODY_BYTES) {
    return new Response('Payload too large', { status: 413 });
  }

  const { overflow, body } = await readBodyWithLimit(request, MAX_BODY_BYTES);
  if (overflow) {
    return new Response('Payload too large', { status: 413 });
  }

  const payload = buildReportPayload({
    sourceIp: request.headers.get('cf-connecting-ip') ?? 'unknown',
    contentType: request.headers.get('content-type') ?? 'unknown',
    body,
  });

  return (await postToDiscord(env.DISCORD_WEBHOOK_URL, payload))
    ? new Response('OK', { status: 200 })
    : new Response('Received, but Discord relay failed', { status: 502 });
}

// ---------- Monitoring: checks ----------
async function checkSite() {
  const attempt = async () => {
    try {
      const response = await fetchWithTimeout(
        SITE_URL,
        { method: 'GET', redirect: 'follow', headers: { 'user-agent': 'iodef-relay-worker-monitor' } },
        CHECK_TIMEOUT_MS,
      );
      await response.body?.cancel().catch(() => {});
      return response.ok ? { ok: true } : { ok: false, detail: `HTTP ${response.status}` };
    } catch (err) {
      // DNS failure, TLS failure (expired/invalid certificate), refused, timeout.
      return { ok: false, detail: err?.message || 'Request failed' };
    }
  };

  const first = await attempt();
  if (first.ok) return first;
  await sleep(SITE_RETRY_DELAY_MS); // one quick retry before counting a failure
  return attempt();
}

async function dnsQuery(name, type) {
  const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=${type}`;
  const response = await fetchWithTimeout(url, { headers: { accept: 'application/dns-json' } }, CHECK_TIMEOUT_MS);
  if (!response.ok) throw new Error(`DNS lookup returned HTTP ${response.status}`);
  const json = await response.json();
  return (json.Answer ?? []).filter((answer) => answer.type === DNS_TYPES[type]);
}

async function checkDns(name, type, needle) {
  try {
    const records = await dnsQuery(name, type);
    if (records.length === 0) return { ok: false, detail: `No ${type} records found for ${name}` };
    if (needle && !records.some((r) => String(r.data).toLowerCase().includes(needle.toLowerCase()))) {
      return { ok: false, detail: `${type} records for ${name} don't contain "${needle}"` };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, detail: err?.message || 'DNS lookup failed' };
  }
}

// Delete any line here that doesn't match your setup.
const CHECKS = [
  { id: 'site', label: 'Website (HTTPS)', run: checkSite },
  { id: 'mx', label: 'MX records (ImprovMX)', run: () => checkDns(DOMAIN, 'MX', 'improvmx.com') },
  { id: 'spf', label: 'SPF record', run: () => checkDns(DOMAIN, 'TXT', 'include:spf.improvmx.com') },
  { id: 'dmarc', label: 'DMARC record', run: () => checkDns(`_dmarc.${DOMAIN}`, 'TXT', 'v=DMARC1') },
  { id: 'caa', label: 'CAA records', run: () => checkDns(DOMAIN, 'CAA') },
];

async function runCheck(check) {
  try {
    return await check.run();
  } catch (err) {
    return { ok: false, detail: err?.message || 'Check crashed' };
  }
}

// ---------- Monitoring: state machine ----------
const EMPTY_CHECK_STATE = { fails: 0, since: null, alertedAt: null };

/**
 * Pure function: previous per-check state + this run's result -> next state
 * and the event to announce (if any). No I/O, so it is easy to reason about.
 */
function evaluateCheck(prev, result, nowMs, threshold) {
  if (result.ok) {
    return {
      next: EMPTY_CHECK_STATE,
      event: prev.alertedAt === null ? null : 'recovered',
    };
  }

  const fails = prev.fails + 1;
  const since = prev.since ?? nowMs;

  if (fails < threshold) {
    return { next: { fails, since, alertedAt: prev.alertedAt }, event: null };
  }
  if (prev.alertedAt === null) {
    return { next: { fails, since, alertedAt: nowMs }, event: 'down' };
  }
  if (nowMs - prev.alertedAt >= REMINDER_INTERVAL_MS) {
    return { next: { fails, since, alertedAt: nowMs }, event: 'reminder' };
  }
  return { next: { fails, since, alertedAt: prev.alertedAt }, event: null };
}

async function loadState(kv) {
  const empty = { checks: {}, lastHeartbeatAt: null };
  if (!kv) return { stateful: false, firstRun: false, state: empty };
  try {
    const saved = await kv.get(STATE_KEY, 'json');
    return { stateful: true, firstRun: saved === null, state: saved ?? empty };
  } catch (err) {
    // Degrade to stateless for this run rather than going silent.
    console.error('KV read failed, running without state:', err);
    return { stateful: false, firstRun: false, state: empty };
  }
}

function buildEventEmbed({ check, result, prev, next, event }) {
  if (event === 'recovered') {
    return embed({
      title: `Recovered: ${check.label}`,
      color: COLORS.recovered,
      fields: [{ name: 'Was failing since', value: prev.since ? relativeTime(prev.since) : 'unknown' }],
    });
  }
  return embed({
    title: event === 'reminder' ? `Still failing: ${check.label}` : `Check failing: ${check.label}`,
    color: event === 'reminder' ? COLORS.reminder : COLORS.down,
    fields: [
      { name: 'Reason', value: result.detail ?? 'Unknown' },
      { name: 'Failing since', value: relativeTime(next.since), inline: true },
      { name: 'Failed runs in a row', value: next.fails, inline: true },
    ],
  });
}

function buildHeartbeatEmbed(evaluated, firstRun) {
  return embed({
    title: firstRun ? 'Monitor started' : 'Weekly heartbeat',
    color: COLORS.heartbeat,
    fields: evaluated.map(({ check, result }) => ({
      name: check.label,
      value: result.ok ? '✅ OK' : `❌ ${result.detail ?? 'Failing'}`,
      inline: true,
    })),
  });
}

async function runMonitor(env, now) {
  const nowMs = now.getTime();
  const { stateful, firstRun, state } = await loadState(env.STATE);
  const threshold = stateful ? FAILURES_BEFORE_ALERT : 1;

  const results = await Promise.all(
    CHECKS.map(async (check) => ({ check, result: await runCheck(check) })),
  );

  const evaluated = results.map(({ check, result }) => {
    const prev = state.checks[check.id] ?? EMPTY_CHECK_STATE;
    return { check, result, prev, ...evaluateCheck(prev, result, nowMs, threshold) };
  });

  const heartbeatDue =
    stateful && (state.lastHeartbeatAt === null || nowMs - state.lastHeartbeatAt >= HEARTBEAT_INTERVAL_MS);

  const embeds = [
    ...evaluated.filter((e) => e.event).map(buildEventEmbed),
    ...(heartbeatDue ? [buildHeartbeatEmbed(evaluated, firstRun)] : []),
  ];

  const delivered = embeds.length === 0 || (await postToDiscord(env.DISCORD_WEBHOOK_URL, discordPayload(embeds)));

  if (!stateful) return;

  // If delivery failed, don't advance the checks that were announcing something,
  // so the same alert is retried on the next run.
  const nextState = {
    checks: Object.fromEntries(
      evaluated.map((e) => [e.check.id, delivered || !e.event ? e.next : e.prev]),
    ),
    lastHeartbeatAt: heartbeatDue && delivered ? nowMs : state.lastHeartbeatAt,
  };

  if (JSON.stringify(nextState) !== JSON.stringify(state)) {
    await env.STATE.put(STATE_KEY, JSON.stringify(nextState));
  }
}

async function handleScheduled(env) {
  if (!env.DISCORD_WEBHOOK_URL) {
    console.error('DISCORD_WEBHOOK_URL is not set; skipping monitor run.');
    return;
  }
  try {
    await runMonitor(env, new Date());
  } catch (err) {
    console.error('Monitor run failed:', err);
    await postToDiscord(
      env.DISCORD_WEBHOOK_URL,
      discordPayload([
        embed({
          title: 'Monitor error',
          color: COLORS.error,
          fields: [{ name: 'Error', value: String(err?.message ?? err) }],
        }),
      ]),
    );
  }
}

export default {
  fetch: handleRequest,
  scheduled: (event, env, ctx) => {
    ctx.waitUntil(handleScheduled(env));
  },
};
