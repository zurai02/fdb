/**
 * iodef-relay-worker.js  --  set-and-forget domain guard for zurai02.is-a.dev
 *
 * What it does
 *   1. Receives CAA `iodef` violation reports (POST) and relays them to Discord.
 *   2. Every cron run, DISCOVERS your DNS records by itself (A, AAAA, CNAME, MX,
 *      TXT, NS, CAA) and checks the website over HTTPS. Nothing about your
 *      records is hard-coded: checks are derived from what DNS actually returns.
 *   3. Detects DRIFT: any record that is added, removed or changed (a changed MX,
 *      a hijacked CNAME, a deleted SPF file...) is announced with a before/after.
 *   4. Alerts ONCE when a check breaks, reminds you daily while it stays broken,
 *      and tells you when it recovers.
 *   5. Posts a weekly heartbeat with a full inventory of every record it found.
 *      If the heartbeat ever stops appearing, the monitor itself is broken --
 *      that is your dead-man's switch.
 *
 * How records are discovered
 *   DNS has no "list everything" command, so the Worker builds the list of names
 *   dynamically, in this order, and queries each one:
 *     - the apex, plus any names in the EXTRA_NAMES variable (comma separated,
 *       e.g. "blog,api,_acme-challenge" -- labels or full names)
 *     - every name it found on previous runs (stored in KV)
 *     - common names: _dmarc, _spf, www, mail and a few DKIM selectors
 *     - every in-domain name that any record points to: CNAME / NS / MX targets
 *       and SPF include:/redirect= targets. So a record in _spf.zurai02.json is
 *       found automatically as soon as your main record includes it.
 *   Add anything else it should watch to EXTRA_NAMES; it is remembered after that.
 *
 * Dynamic checks (all derived from live DNS)
 *   apex   the apex has an A, AAAA or CNAME record
 *   mx     MX records, mail provider auto-detected (ImprovMX, Google, Proton, ...)
 *   spf    follows include:/redirect= chains, requires the detected provider's SPF
 *          to be reachable, flags duplicates, +all, loops and the 10-lookup limit
 *   dmarc  exactly one valid record whenever mail is in use
 *   caa    CAA records exist (and whether an iodef tag is set)
 *   cname  no in-domain CNAME points at a target that no longer resolves
 *   site   the website answers over HTTPS
 *
 * Setup (one time)
 *   - Secret   DISCORD_WEBHOOK_URL   (Settings -> Variables and Secrets, Production)
 *   - KV       Create a KV namespace, then Settings -> Bindings -> add it with the
 *              variable name  STATE.  Optional but strongly recommended: without it
 *              the Worker still runs, but there is no drift detection, alerts fire on
 *              every failed run, and there is no recovery notice, heartbeat or
 *              report rate limit.
 *   - Cron     Settings -> Triggers -> Cron Triggers -> 0 * * * *  (hourly, UTC)
 *   - CAA      { "flags": 0, "tag": "iodef", "value": "<this Worker's hostname>" }
 *   - Optional variables: EXTRA_NAMES (see above), DNS_BUDGET (see below)
 *
 * The first cron run posts a "Monitor started" message with every check and the
 * discovered inventory; that run records the baseline that drift is compared to.
 *
 * Limits
 *   The free Workers plan allows 50 subrequests (outbound fetches and KV calls)
 *   per run, so DNS lookups are capped by DNS_BUDGET (default 36). Names that do
 *   not fit are listed as "skipped" in the heartbeat. On a paid plan set the
 *   DNS_BUDGET variable to something like 200.
 *
 * Design notes
 *   - Checks only alert after FAILURES_BEFORE_ALERT consecutive failed runs, and a
 *     record change must be seen on that many consecutive runs, so a one-off
 *     network blip or resolver hiccup never pages you.
 *   - A failed lookup (SERVFAIL, timeout) is never treated as "record removed".
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
const DOMAIN = 'zurai02.is-a.dev';
const SITE_URL = `https://${DOMAIN}/`;

// Names that are always looked at, besides the apex and whatever is discovered.
const COMMON_LABELS = [
  '_dmarc',
  '_spf',
  'www',
  'mail',
  'default._domainkey',
  'google._domainkey',
  'selector1._domainkey',
  'selector2._domainkey',
  'k1._domainkey',
];

// MX host suffix -> the SPF domain that provider's mail needs. Add your own.
const MAIL_PROVIDERS = [
  { match: 'improvmx.com', name: 'ImprovMX', spf: 'spf.improvmx.com' },
  { match: 'google.com', name: 'Google Workspace', spf: '_spf.google.com' },
  { match: 'googlemail.com', name: 'Google Workspace', spf: '_spf.google.com' },
  { match: 'protonmail.ch', name: 'Proton Mail', spf: '_spf.protonmail.ch' },
  { match: 'mail.protection.outlook.com', name: 'Microsoft 365', spf: 'spf.protection.outlook.com' },
  { match: 'messagingengine.com', name: 'Fastmail', spf: 'spf.messagingengine.com' },
];

const DNS_BUDGET_DEFAULT = 36; // free plan: 50 subrequests per run in total
const CHECK_RESERVE = 6; // lookups kept back for the SPF/DMARC checks
const MAX_NAMES = 40;
const SPF_MAX_LOOKUPS = 10; // RFC 7208 limit
const SPF_MAX_DEPTH = 6;

const MAX_BODY_BYTES = 8_000;
const MAX_REPORTS_PER_HOUR = 20;

const DISCORD_TIMEOUT_MS = 5_000;
const DISCORD_MAX_RETRIES = 2;
const DISCORD_DEFAULT_RETRY_MS = 1_000;
const DISCORD_MAX_RETRY_MS = 5_000;
const DISCORD_FIELD_LIMIT = 1_000;
const DISCORD_EMBEDS_PER_MESSAGE = 10;

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
  change: 0xf1c40f,
  error: 0x95a5a6,
};

const DNS_TYPES = { A: 1, NS: 2, CNAME: 5, MX: 15, TXT: 16, AAAA: 28, CAA: 257 };
const TYPE_NAMES = Object.fromEntries(Object.entries(DNS_TYPES).map(([name, number]) => [number, name]));

// ---------- Small helpers ----------
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const clip = (text, max = DISCORD_FIELD_LIMIT) =>
  text.length > max ? `${text.slice(0, max - 16)}\n... (truncated)` : text;

const relativeTime = (ms) => `<t:${Math.floor(ms / 1000)}:R>`;

const host = (value) => String(value).trim().toLowerCase().replace(/\.$/, '');

const sameList = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);

const inDomain = (name) => name === DOMAIN || name.endsWith(`.${DOMAIN}`);

const shortName = (name) => (name === DOMAIN ? '@' : name.endsWith(`.${DOMAIN}`) ? name.slice(0, -(DOMAIN.length + 1)) : name);

// "blog" -> blog.<domain>, "@" -> the apex, full names are kept.
function toName(label) {
  const clean = host(label);
  if (clean === '' || clean === '@') return DOMAIN;
  return inDomain(clean) ? clean : `${clean}.${DOMAIN}`;
}

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

// Discord accepts at most 10 embeds per message, so send them in chunks.
async function postEmbeds(webhookUrl, embeds) {
  for (let i = 0; i < embeds.length; i += DISCORD_EMBEDS_PER_MESSAGE) {
    const chunk = embeds.slice(i, i + DISCORD_EMBEDS_PER_MESSAGE);
    if (!(await postToDiscord(webhookUrl, discordPayload(chunk)))) return false;
  }
  return true;
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

// ---------- DNS: resolver with a per-run cache and subrequest budget ----------
class BudgetError extends Error {}

async function dnsQuery(name, type) {
  const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=${type}`;
  const response = await fetchWithTimeout(url, { headers: { accept: 'application/dns-json' } }, CHECK_TIMEOUT_MS);
  if (!response.ok) throw new Error(`DNS lookup returned HTTP ${response.status}`);
  const json = await response.json();
  // SERVFAIL is a failed lookup, not an empty answer: never read it as "removed".
  if (json.Status === 2) throw new Error(`SERVFAIL for ${name}`);
  return json.Answer ?? [];
}

function createResolver(budget) {
  const cache = new Map();
  let used = 0;
  return {
    budget,
    used: () => used,
    remaining: () => budget - used,
    query(name, type) {
      const key = `${host(name)}|${type}`;
      const cached = cache.get(key);
      if (cached) return cached;
      if (used >= budget) return Promise.reject(new BudgetError('DNS query budget reached'));
      used += 1;
      const promise = dnsQuery(host(name), type);
      cache.set(key, promise);
      return promise;
    },
  };
}

// TXT data arrives quoted and split into 255-byte chunks: "abc" "def" -> abcdef
const txtValue = (data) => String(data).replace(/"\s*"/g, '').replace(/^"|"$/g, '');

// CAA often arrives as RFC 3597 hex ("\# 22 00 05 ...") -> `0 issue "letsencrypt.org"`
function decodeCaa(data) {
  const text = String(data).trim();
  if (!text.startsWith('\\#')) return text;
  const bytes = (text.split(/\s+/).slice(2).join('').match(/../g) ?? []).map((pair) => parseInt(pair, 16));
  const tagLength = bytes[1] ?? 0;
  const tag = String.fromCharCode(...bytes.slice(2, 2 + tagLength));
  const value = String.fromCharCode(...bytes.slice(2 + tagLength));
  return `${bytes[0] ?? 0} ${tag} "${value}"`;
}

function recordValue(type, data) {
  switch (type) {
    case 'TXT':
      return txtValue(data);
    case 'CAA':
      return decodeCaa(data);
    case 'CNAME':
    case 'NS':
      return host(data);
    case 'MX': {
      const [preference, target] = String(data).trim().split(/\s+/);
      return `${preference} ${host(target ?? '')}`;
    }
    default:
      return String(data).trim().toLowerCase();
  }
}

async function lookupTxt(resolver, name) {
  const answers = await resolver.query(name, DNS_TYPES.TXT);
  return answers.filter((answer) => answer.type === DNS_TYPES.TXT).map((answer) => txtValue(answer.data));
}

// ---------- DNS: discovery ----------
// Which record types to ask for at a given name.
function typesFor(name) {
  if (name === DOMAIN) return ['A', 'AAAA', 'MX', 'TXT', 'NS', 'CAA'];
  if (/(^|\.)_/.test(name)) return ['TXT']; // _dmarc, _spf, x._domainkey, ...
  return ['A', 'AAAA', 'TXT'];
}

const isSpf = (text) => /^v=spf1(\s|$)/i.test(text);

// In-domain names that a record points to: how new names are discovered.
function referencedHosts(type, value) {
  let candidates = [];
  if (type === 'CNAME' || type === 'NS') candidates = [value];
  else if (type === 'MX') candidates = [value.split(' ')[1]];
  else if (type === 'TXT' && isSpf(value)) {
    candidates = value
      .toLowerCase()
      .split(/\s+/)
      .map((term) => term.replace(/^[+\-~?]/, '').match(/^(?:include:|redirect=|a:|mx:)([^/]+)/)?.[1]);
  }
  return candidates
    .filter(Boolean)
    .map(host)
    .filter((name) => !name.includes('%') && inDomain(name));
}

/**
 * Fetches every record type for one name. Returns null if the lookup budget
 * cannot cover it. `values[TYPE]` is a sorted list, or absent when that lookup
 * failed (so a failed lookup is never compared as "empty").
 */
async function fetchName(resolver, name) {
  const types = typesFor(name);
  if (resolver.remaining() - CHECK_RESERVE < types.length) return null;

  const results = await Promise.all(
    types.map(async (type) => {
      try {
        return { type, answers: await resolver.query(name, DNS_TYPES[type]) };
      } catch (error) {
        return { type, error };
      }
    }),
  );

  const sets = {};
  const errors = [];
  const succeeded = new Set();
  let addressSeen = false;

  for (const { type, answers, error } of results) {
    if (error) {
      errors.push(`${type}: ${error.message}`);
      continue;
    }
    succeeded.add(type);
    for (const answer of answers) {
      if (answer.type === DNS_TYPES.A || answer.type === DNS_TYPES.AAAA) addressSeen = true;
      const recordType = TYPE_NAMES[answer.type];
      // Only records owned by this exact name (not a CNAME target's records).
      if (!recordType || host(answer.name) !== name) continue;
      (sets[recordType] ??= new Set()).add(recordValue(recordType, answer.data));
    }
  }

  const values = {};
  for (const type of succeeded) values[type] = [...(sets[type] ?? [])].sort();
  if (succeeded.size > 0) values.CNAME = [...(sets.CNAME ?? [])].sort();

  const dangling = (values.CNAME?.length ?? 0) > 0 && succeeded.has('A') && succeeded.has('AAAA') && !addressSeen;
  return { name, values, errors, dangling };
}

function buildSeedNames(env, state) {
  const extra = String(env.EXTRA_NAMES ?? '')
    .split(',')
    .map((label) => label.trim())
    .filter(Boolean)
    .map(toName);
  const remembered = Object.keys(state.records ?? {}).map((key) => key.split('|')[0]);
  return [DOMAIN, ...extra, ...remembered, ...COMMON_LABELS.map(toName)];
}

// Breadth-first: look up each name, queue any in-domain name its records mention.
async function discover(resolver, seeds) {
  const queue = [];
  const seen = new Set();
  const enqueue = (name) => {
    const clean = host(name);
    if (!seen.has(clean) && queue.length < MAX_NAMES) {
      seen.add(clean);
      queue.push(clean);
    }
  };
  seeds.forEach(enqueue);

  const records = new Map();
  const skippedNames = [];

  for (let i = 0; i < queue.length; i += 1) {
    const record = await fetchName(resolver, queue[i]);
    if (!record) {
      skippedNames.push(queue[i]);
      continue;
    }
    records.set(record.name, record);
    for (const [type, values] of Object.entries(record.values)) {
      for (const value of values) referencedHosts(type, value).forEach(enqueue);
    }
  }
  return { records, skippedNames };
}

// { "name|TYPE": [values] } for every record set that was looked up successfully.
function snapshotOf(records) {
  const current = {};
  for (const record of records.values()) {
    for (const [type, values] of Object.entries(record.values)) current[`${record.name}|${type}`] = values;
  }
  return current;
}

function buildInventory(records) {
  const lines = [];
  for (const record of records.values()) {
    const parts = Object.entries(record.values)
      .filter(([, values]) => values.length > 0)
      .map(([type, values]) => `${type}×${values.length}`);
    if (parts.length > 0) lines.push(`${shortName(record.name)}: ${parts.join(' ')}`);
  }
  return lines.join('\n') || 'No records found';
}

// ---------- DNS: drift detection ----------
/**
 * Compares this run's record sets to the stored baseline. A difference must be
 * seen on `threshold` consecutive runs before it is announced and adopted.
 * With no baseline yet, everything is adopted silently.
 */
function evaluateDrift(state, current, threshold) {
  const baselining = !state.records;
  const records = { ...(state.records ?? {}) };
  const pending = { ...(state.pending ?? {}) };
  const changes = [];

  for (const [key, values] of Object.entries(current)) {
    const base = records[key] ?? [];
    if (sameList(values, base)) {
      delete pending[key];
      continue;
    }

    const adopt = () => {
      if (values.length > 0) records[key] = values;
      else delete records[key];
      delete pending[key];
    };

    if (baselining) {
      adopt();
      continue;
    }

    const runs = pending[key] && sameList(pending[key].values, values) ? pending[key].runs + 1 : 1;
    if (runs >= threshold) {
      changes.push({
        key,
        added: values.filter((value) => !base.includes(value)),
        removed: base.filter((value) => !values.includes(value)),
      });
      adopt();
    } else {
      pending[key] = { values, runs };
    }
  }
  return { baselining, records, pending, changes };
}

function buildChangeEmbed({ key, added, removed }) {
  const [name, type] = key.split('|');
  return embed({
    title: `DNS change: ${shortName(name)} ${type}`,
    color: COLORS.change,
    fields: [
      { name: 'Added', value: added.length > 0 ? added.join('\n') : '-' },
      { name: 'Removed', value: removed.length > 0 ? removed.join('\n') : '-' },
    ],
  });
}

// ---------- Monitoring: checks ----------
const skipped = (detail) => ({ ok: true, skipped: true, detail });

const failure = (err, fallback) =>
  err instanceof BudgetError ? skipped('skipped: DNS query budget reached') : { ok: false, detail: err?.message || fallback };

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

function detectMailProvider(mxValues) {
  const hosts = mxValues.map((value) => value.split(' ')[1] ?? '');
  return MAIL_PROVIDERS.find((p) => hosts.some((h) => h === p.match || h.endsWith(`.${p.match}`)));
}

/**
 * Walks one SPF record and everything it includes/redirects to, collecting
 * every hop in `walk.visited` and every problem in `walk.problems`.
 */
async function walkSpf(name, walk, depth = 0) {
  const key = name.toLowerCase();
  if (depth > SPF_MAX_DEPTH) {
    walk.problems.push(`Include chain deeper than ${SPF_MAX_DEPTH} at ${name}`);
    return;
  }
  if (walk.visited.has(key)) {
    walk.problems.push(`SPF include loop at ${name}`);
    return;
  }
  walk.visited.add(key);

  const records = (await lookupTxt(walk.resolver, name)).filter(isSpf);
  if (records.length === 0) {
    walk.problems.push(`No SPF record at ${name}`);
    return;
  }
  if (records.length > 1) {
    walk.problems.push(`${records.length} SPF records at ${name} (only one is allowed)`);
    return;
  }

  const terms = records[0].trim().split(/\s+/).slice(1).map((term) => term.toLowerCase());

  if (depth === 0 && !terms.some((t) => /^[+\-~?]?all$/.test(t) || t.startsWith('redirect='))) {
    walk.problems.push(`SPF at ${name} has no "all" ending (add ~all or -all)`);
  }

  for (const term of terms) {
    if (term === 'all' || term === '+all') {
      walk.problems.push(`${name} uses +all (lets anyone send as you)`);
      continue;
    }
    const mechanism = term.replace(/^[+\-~?]/, '');

    if (/^(include:|redirect=)/.test(mechanism)) {
      walk.lookups += 1;
      const target = mechanism.replace(/^(include:|redirect=)/, '');
      if (target && !target.includes('%')) await walkSpf(target, walk, depth + 1);
    } else if (/^(a|mx|ptr|exists)([:/]|$)/.test(mechanism)) {
      walk.lookups += 1;
    }
  }
}

async function checkSpf(resolver, domain, requiredProvider) {
  try {
    const walk = { resolver, visited: new Set(), problems: [], lookups: 0 };
    await walkSpf(domain, walk);

    const chain = [...walk.visited].join(' -> ');
    if (walk.lookups > SPF_MAX_LOOKUPS) {
      walk.problems.push(`${walk.lookups} DNS lookups (limit is ${SPF_MAX_LOOKUPS})`);
    }
    if (requiredProvider && !walk.visited.has(requiredProvider.toLowerCase())) {
      walk.problems.push(`Chain never reaches ${requiredProvider} (followed: ${chain})`);
    }

    return walk.problems.length > 0
      ? { ok: false, detail: walk.problems.join('; ') }
      : { ok: true, detail: chain };
  } catch (err) {
    return failure(err, 'SPF lookup failed');
  }
}

async function checkDmarcRecord(resolver, domain) {
  try {
    const name = `_dmarc.${domain}`;
    const records = (await lookupTxt(resolver, name)).filter((text) => /^v=dmarc1\s*(;|$)/i.test(text));
    if (records.length === 0) return { ok: false, missing: true, detail: `No DMARC record at ${name}` };
    if (records.length > 1) return { ok: false, detail: `${records.length} DMARC records at ${name} (only one is allowed)` };

    const policy = records[0].match(/;\s*p=(none|quarantine|reject)\b/i);
    if (!policy) return { ok: false, detail: `DMARC at ${name} has no valid p= policy` };
    return { ok: true, detail: `p=${policy[1].toLowerCase()}` };
  } catch (err) {
    return failure(err, 'DMARC lookup failed');
  }
}

const apexOf = (ctx) => ctx.records.get(DOMAIN);

const lookupFailed = (apex, type) => ({
  ok: false,
  detail: apex.errors.find((message) => message.startsWith(`${type}:`)) ?? `${type} lookup failed`,
});

function checkApex(ctx) {
  const apex = apexOf(ctx);
  if (!apex) return skipped('skipped: DNS query budget reached');
  const count = ['A', 'AAAA', 'CNAME'].reduce((sum, type) => sum + (apex.values[type]?.length ?? 0), 0);
  if (count > 0) return { ok: true, detail: `${count} address record${count === 1 ? '' : 's'}` };
  if (apex.errors.length > 0) return { ok: false, detail: apex.errors[0] };
  return { ok: false, detail: `No A, AAAA or CNAME records for ${DOMAIN}` };
}

function checkMx(ctx) {
  const apex = apexOf(ctx);
  if (!apex) return skipped('skipped: DNS query budget reached');
  const mx = apex.values.MX;
  if (!mx) return lookupFailed(apex, 'MX');
  if (mx.length === 0) return { ok: true, detail: 'none configured' };
  const provider = detectMailProvider(mx);
  return { ok: true, detail: `${mx.length} MX${provider ? ` (${provider.name})` : ''}` };
}

function checkSpfRecord(ctx) {
  const apex = apexOf(ctx);
  if (!apex) return skipped('skipped: DNS query budget reached');
  const txt = apex.values.TXT;
  if (!txt) return lookupFailed(apex, 'TXT');
  const mx = apex.values.MX ?? [];
  if (mx.length === 0 && !txt.some(isSpf)) return { ok: true, detail: 'not used' };
  return checkSpf(ctx.resolver, DOMAIN, detectMailProvider(mx)?.spf);
}

async function checkDmarc(ctx) {
  const apex = apexOf(ctx);
  if (!apex) return skipped('skipped: DNS query budget reached');
  const mailInUse = (apex.values.MX ?? []).length > 0 || (apex.values.TXT ?? []).some(isSpf);
  const result = await checkDmarcRecord(ctx.resolver, DOMAIN);
  if (result.missing && !mailInUse) return { ok: true, detail: 'not used' };
  return result;
}

function checkCaa(ctx) {
  const apex = apexOf(ctx);
  if (!apex) return skipped('skipped: DNS query budget reached');
  const caa = apex.values.CAA;
  if (!caa) return lookupFailed(apex, 'CAA');
  if (caa.length === 0) return { ok: false, detail: `No CAA records found for ${DOMAIN}` };
  return { ok: true, detail: caa.some((value) => /\biodef\b/i.test(value)) ? 'iodef set' : 'no iodef tag' };
}

function checkCnames(ctx) {
  const all = [...ctx.records.values()].filter((record) => (record.values.CNAME?.length ?? 0) > 0);
  const dangling = all.filter((record) => record.dangling).map((record) => shortName(record.name));
  if (dangling.length > 0) return { ok: false, detail: `CNAME target has no address records: ${dangling.join(', ')}` };
  return { ok: true, detail: all.length > 0 ? `${all.length} CNAME${all.length === 1 ? '' : 's'} resolve` : 'none' };
}

// Every check receives { resolver, records, skippedNames } from discovery.
const CHECKS = [
  { id: 'site', label: 'Website (HTTPS)', run: () => checkSite() },
  { id: 'apex', label: 'Apex address records', run: checkApex },
  { id: 'mx', label: 'MX records', run: checkMx },
  { id: 'spf', label: 'SPF (follows includes)', run: checkSpfRecord },
  { id: 'dmarc', label: 'DMARC record', run: checkDmarc },
  { id: 'caa', label: 'CAA records', run: checkCaa },
  { id: 'cname', label: 'CNAME targets', run: checkCnames },
];

async function runCheck(check, ctx) {
  try {
    return await check.run(ctx);
  } catch (err) {
    return failure(err, 'Check crashed');
  }
}

// ---------- Monitoring: state machine ----------
const EMPTY_CHECK_STATE = { fails: 0, since: null, alertedAt: null };

/**
 * Pure function: previous per-check state + this run's result -> next state
 * and the event to announce (if any). No I/O, so it is easy to reason about.
 * A skipped check (e.g. out of lookup budget) changes nothing.
 */
function evaluateCheck(prev, result, nowMs, threshold) {
  if (result.skipped) return { next: prev, event: null };

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

function buildHeartbeatEmbed({ title, evaluated, discovery, resolver }) {
  const fields = evaluated.map(({ check, result }) => ({
    name: check.label,
    value: result.skipped
      ? `⏭️ ${result.detail}`
      : result.ok
        ? `✅ OK${result.detail ? ` (${result.detail})` : ''}`
        : `❌ ${result.detail ?? 'Failing'}`,
    inline: true,
  }));

  fields.push({ name: `Records discovered (${discovery.records.size} names)`, value: buildInventory(discovery.records) });
  if (discovery.skippedNames.length > 0) {
    fields.push({
      name: 'Skipped (DNS query budget)',
      value: `${discovery.skippedNames.map(shortName).join(', ')}\nRaise DNS_BUDGET if you are on a paid plan.`,
    });
  }
  fields.push({ name: 'DNS lookups used', value: `${resolver.used()} / ${resolver.budget}`, inline: true });

  return embed({ title, color: COLORS.heartbeat, fields });
}

async function runMonitor(env, now) {
  const nowMs = now.getTime();
  const { stateful, firstRun, state } = await loadState(env.STATE);
  const threshold = stateful ? FAILURES_BEFORE_ALERT : 1;

  const resolver = createResolver(Number(env.DNS_BUDGET) > 0 ? Number(env.DNS_BUDGET) : DNS_BUDGET_DEFAULT);
  const discovery = await discover(resolver, buildSeedNames(env, state));
  const ctx = { resolver, records: discovery.records, skippedNames: discovery.skippedNames };

  const results = await Promise.all(CHECKS.map(async (check) => ({ check, result: await runCheck(check, ctx) })));

  const evaluated = results.map(({ check, result }) => {
    const prev = state.checks[check.id] ?? EMPTY_CHECK_STATE;
    return { check, result, prev, ...evaluateCheck(prev, result, nowMs, threshold) };
  });

  // Drift needs a stored baseline, so it only runs when KV is available.
  const drift = stateful
    ? evaluateDrift(state, snapshotOf(discovery.records), threshold)
    : { baselining: false, records: undefined, pending: undefined, changes: [] };

  const heartbeatDue =
    stateful &&
    (drift.baselining || state.lastHeartbeatAt === null || nowMs - state.lastHeartbeatAt >= HEARTBEAT_INTERVAL_MS);

  const heartbeatTitle = firstRun ? 'Monitor started' : drift.baselining ? 'DNS baseline recorded' : 'Weekly heartbeat';

  const embeds = [
    ...evaluated.filter((e) => e.event).map(buildEventEmbed),
    ...drift.changes.map(buildChangeEmbed),
    ...(heartbeatDue ? [buildHeartbeatEmbed({ title: heartbeatTitle, evaluated, discovery, resolver })] : []),
  ];

  const delivered = embeds.length === 0 || (await postEmbeds(env.DISCORD_WEBHOOK_URL, embeds));

  if (!stateful) return;

  // If delivery failed, don't advance anything that was announcing something,
  // so the same alert is retried on the next run instead of being lost.
  const keepOldDrift = !delivered && (drift.changes.length > 0 || drift.baselining);
  const nextState = {
    checks: Object.fromEntries(
      evaluated.map((e) => [e.check.id, delivered || !e.event ? e.next : e.prev]),
    ),
    lastHeartbeatAt: heartbeatDue && delivered ? nowMs : state.lastHeartbeatAt,
    records: keepOldDrift ? state.records : drift.records,
    pending: keepOldDrift ? state.pending : drift.pending,
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
