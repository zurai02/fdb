--!strict
--!optimize 2
-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  SWIM SYSTEM  v6                                                    ║
-- ╠══════════════════════════════════════════════════════════════════════╣
-- ║  All v5 features and optimisations kept.  New in v6:               ║
-- ║                                                                     ║
-- ║  DYNAMIC SURFACE BUOYANCY                                           ║
-- ║    When within CFG.BUOY_DEPTH studs of the surface and not         ║
-- ║    actively sinking, a buoyancy spring nudges the Y component of   ║
-- ║    targetVelocity upward, so floating near the top feels natural    ║
-- ║    without pressing Rise.  Strength scales linearly with proximity. ║
-- ║                                                                     ║
-- ║  BREATH-CYCLE BOB                                                   ║
-- ║    While idle at the surface (speed < 20 % of max) a 0.4 Hz sine   ║
-- ║    drives a ±CFG.BOB_AMPLITUDE stud Y oscillation, giving the     ║
-- ║    impression of breathing / floating.  Fades out as speed rises.  ║
-- ║                                                                     ║
-- ║  MOMENTUM-PRESERVING DIVE ENTRY                                     ║
-- ║    On water entry the full XZ velocity is preserved; only the Y    ║
-- ║    component is clamped.  A running dive now carries its momentum   ║
-- ║    into the water instead of halting horizontally.                  ║
-- ║                                                                     ║
-- ║  PREDICTIVE EXIT ARC                                                ║
-- ║    On a Rising exit the XZ component of curVel at the moment of    ║
-- ║    breaking the surface is applied as a forward impulse so you arc  ║
-- ║    out of the water rather than popping straight up.               ║
-- ║                                                                     ║
-- ║  PER-DIVE STATS                                                     ║
-- ║    diveStartTime, maxDepthReached, and diveDist are tracked per     ║
-- ║    entry and written to the hitbox as Attributes on exit so server  ║
-- ║    scripts can read them (e.g. for achievements / scoring).        ║
-- ║                                                                     ║
-- ║  SCREEN-SPACE DISTORTION PULSE                                      ║
-- ║    ColorCorrectionEffect.Brightness pulses with a sin wave tied to  ║
-- ║    swim speed while underwater — a subtle lens-undulation effect.   ║
-- ║    Amplitude = CFG.DISTORT_AMPLITUDE * speedFactor.                ║
-- ║                                                                     ║
-- ║  SPEED-ADAPTIVE FOAM COLOR                                          ║
-- ║    The foam emitter ColorSequence shifts from cool white-blue at    ║
-- ║    idle to warm bright-white at full sprint.  Written at most once  ║
-- ║    per CFG.FOAM_COLOR_INTERVAL seconds to avoid per-frame GC.      ║
-- ║                                                                     ║
-- ║  BOW-WAVE EXPANSION RING                                            ║
-- ║    At sprint speed (sf > CFG.BOW_WAVE_THRESHOLD) a third, larger   ║
-- ║    ring layer on surfaceFx slowly expands (scale 1 → 1.6) and then ║
-- ║    fades, giving a bow-wave feel.  Driven purely by scalars.       ║
-- ║                                                                     ║
-- ║  DIRECTIONAL STREAK SPREAD                                          ║
-- ║    Splash streaks now bias their launch angles toward the swimmer's ║
-- ║    look direction so they fan forward rather than in a perfect      ║
-- ║    circle. Bias strength = CFG.STREAK_DIR_BIAS (0 = symmetric).   ║
-- ║                                                                     ║
-- ║  DEPTH-SCALED STREAK WIDTH                                          ║
-- ║    Trail WidthScale peak scales with maxDepthReached at the moment  ║
-- ║    of the splash — deep dives produce wider, more dramatic streaks. ║
-- ║                                                                     ║
-- ║  ADAPTIVE SURFACE RE-CHECK RATE                                     ║
-- ║    surfaceTimer tightens to CFG.SURFACE_TIMER_NEAR (0.04 s) when  ║
-- ║    the player is within CFG.SURFACE_NEAR_DIST of the surface,      ║
-- ║    ensuring the exit-splash position is always precise.             ║
-- ║                                                                     ║
-- ║  RIPPLE FAST-EXIT ON EXIT                                           ║
-- ║    On water exit all active ripples have their remaining life       ║
-- ║    halved so they clear quickly instead of lingering.               ║
-- ║                                                                     ║
-- ║  FOAM RATE MOVED TO PHYSICS LOOP                                    ║
-- ║    surfaceFx.foam.Rate is now set in PreSimulation where speed is   ║
-- ║    already computed, one frame earlier than in v5's PreRender.      ║
-- ╚══════════════════════════════════════════════════════════════════════╝

local ContextActionService = game:GetService("ContextActionService")
local RunService           = game:GetService("RunService")
local Players              = game:GetService("Players")
local Workspace            = game:GetService("Workspace")
local CollectionService    = game:GetService("CollectionService")
local TweenService         = game:GetService("TweenService")
local Lighting             = game:GetService("Lighting")
local Debris               = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local IS_STUDIO   = RunService:IsStudio()

-- ─── CONFIG ──────────────────────────────────────────────────────────────────
local CFG = {
	-- movement
	SWIM_SPEED            = 22,
	RISE_SPEED            = 16,
	SINK_SPEED            = 16,
	ENTRY_MAX_SPEED       = 60,
	EXIT_JUMP_BONUS       = 8,

	-- v6: buoyancy near surface
	BUOY_DEPTH            = 1.2,   -- studs below surface where buoyancy activates
	BUOY_STRENGTH         = 6.0,   -- max upward push (studs/s) applied at surface level

	-- v6: breath-cycle bob
	BOB_AMPLITUDE         = 0.18,  -- studs of Y oscillation while idle at surface
	BOB_FREQ              = 0.4,   -- Hz of the bob cycle
	BOB_SPEED_FADE        = 0.3,   -- speedFactor above which bob fades out completely

	-- velocity spring
	VEL_STIFFNESS         = 180,
	VEL_DAMPING           = 26,

	-- orientation spring
	ORI_OMEGA             = 14,
	ORI_ZETA              = 0.85,
	TILT_MAX              = 38,
	TILT_OMEGA            = 10,
	TILT_ZETA             = 0.9,
	BANK_MAX              = 18,
	BANK_OMEGA            = 8,
	BANK_ZETA             = 0.7,

	-- camera lean
	CAM_LEAN_MAX          = 4,
	CAM_LEAN_OMEGA        = 6,
	CAM_LEAN_ZETA         = 0.8,

	-- v6: screen-space distortion pulse
	DISTORT_AMPLITUDE     = 0.018,  -- peak Brightness swing at full speed
	DISTORT_FREQ          = 1.1,    -- Hz of the distortion pulse

	-- underwater current drift
	CURRENT_STRENGTH      = 1.8,
	CURRENT_FREQ_X        = 0.11,
	CURRENT_FREQ_Z        = 0.07,
	CURRENT_DEPTH_SCALE   = 0.6,

	-- underwater look
	BLUR_SIZE             = 8,
	BLUR_TWEEN_TIME       = 0.35,
	UNDERWATER_FOG_END    = 80,
	UNDERWATER_FOG_COLOR  = Color3.fromRGB(30, 90, 160),
	FOG_DEPTH_SCALE       = 0.55,
	FOG_ADAPT_RATE        = 3,
	BUBBLE_RATE           = 18,
	BUBBLE_MOVE_RATE      = 36,

	-- 3-D bubble physics
	BUBBLE_POOL_SIZE      = 48,
	BUBBLE_DRAG           = 2.8,
	BUBBLE_BUOYANCY       = 5.5,
	BUBBLE_SPREAD         = 0.9,

	-- surface ripples
	RING_CORE_COLOR       = Color3.fromRGB(214, 244, 255),
	RING_HALO_COLOR       = Color3.fromRGB(140, 205, 255),
	RING_CORE_COLOR_FAST  = Color3.fromRGB(255, 255, 255),
	RING_HALO_COLOR_FAST  = Color3.fromRGB(200, 235, 255),
	RING_CORE_PX          = 3,
	RING_HALO_PX          = 10,
	RIPPLE_TWEEN_TIME     = 1.0,
	ENTRY_RING_DIAMETER   = 16,
	WAKE_RING_DIAMETER    = 9,
	WAKE_RING_INTERVAL    = 0.28,
	SWIRL_DIAMETER        = 8,
	SWIRL_SPEED           = 70,
	SWIRL_FOLLOW_RATE     = 60,
	RIPPLE_POOL_SIZE      = 24,

	-- wake turbulence
	WAKE_LANE_WIDTH       = 1.4,
	WAKE_LIFE_VARIANCE    = 0.25,
	WAKE_DIAM_VARIANCE    = 0.3,

	-- crest detection
	CREST_CHECK_DIST      = 4.0,
	CREST_RING_THRESH     = 0.18,

	-- foam & splash
	FOAM_TEXTURE          = "rbxasset://textures/particles/smoke_main.dds",
	DROP_TEXTURE          = "rbxassetid://243660364",
	FOAM_RATE             = 10,
	SPLASH_PUFFS          = 12,
	SPLASH_DROPS          = 10,
	SPLASH_STREAKS        = 8,

	-- v6: foam color shift
	FOAM_COLOR_SLOW       = Color3.fromRGB(210, 238, 255),  -- idle colour
	FOAM_COLOR_FAST       = Color3.fromRGB(255, 255, 248),  -- sprint colour
	FOAM_COLOR_INTERVAL   = 0.12,    -- seconds between ColorSequence writes

	-- v6: bow-wave expansion ring
	BOW_WAVE_THRESHOLD    = 0.72,    -- speedFactor at which bow wave appears
	BOW_WAVE_EXPAND_TIME  = 1.8,     -- seconds to grow from 1× to BOW_WAVE_SCALE
	BOW_WAVE_SCALE        = 1.65,    -- max size multiplier

	-- v6: directional streak bias
	STREAK_DIR_BIAS       = 0.55,    -- 0 = perfectly circular, 1 = fully forward fan

	-- v6: depth-scaled streak width
	STREAK_WIDTH_BASE     = 1.0,     -- trail peak width at 0 depth
	STREAK_WIDTH_DEEP     = 2.2,     -- trail peak width at max depth (clamped)
	STREAK_DEEP_REF       = 12.0,    -- depth that maps to STREAK_WIDTH_DEEP

	-- caustic shimmer
	CAUSTIC_LAYERS        = 5,
	CAUSTIC_SPEED         = 0.35,
	CAUSTIC_ALPHA_BASE    = 0.78,
	CAUSTIC_ALPHA_PULSE   = 0.14,

	-- surface placement
	SURFACE_OFFSET        = 0.12,
	SURFACE_FX_FULL_DEPTH = 2.5,
	SURFACE_FX_DEPTH      = 7,
	ENTRY_MAX_DEPTH       = 6,

	-- v6: adaptive surface re-check
	SURFACE_TIMER_FAR     = 0.10,    -- re-check interval when deep
	SURFACE_TIMER_NEAR    = 0.04,    -- re-check interval when near surface
	SURFACE_NEAR_DIST     = 1.8,     -- studs from surface to switch to fast re-check

	-- fixed-tick physics
	SWIM_TICK_RATE        = 120,
	MAX_TICKS_PER_FRAME   = 12,
	LOOK_TURN_RATE        = 14,

	-- hitbox
	BODY_WIDTH            = 2.2,
	BODY_THICKNESS        = 1.8,
	BODY_LENGTH_PAD       = 0.2,
	SLIDE_SKIN            = 0.12,
	SLIDE_CAST_SHRINK     = 0.1,
	SLIDE_MAX_BOUNCES     = 3,
	SHOW_HITBOX           = false,

	-- animation fallbacks
	FALLBACK_IDLE_ANIM    = "rbxassetid://913384386",
	FALLBACK_SWIM_ANIM    = "rbxassetid://913389033",
}

local BIND_RISE = "CustomSwim_Rise"
local BIND_SINK = "CustomSwim_Sink"
local SWIM_TICK = 1 / CFG.SWIM_TICK_RATE
local VOXEL       = 4
local RING_CANVAS = 384
local RING_MARGIN = 14
local TAU         = math.pi * 2

-- ─── PRE-COMPUTED CONSTANTS ──────────────────────────────────────────────────
local V3_ZERO        = Vector3.zero
local V3_UP          = Vector3.yAxis
local V3_SINK_IDLE   = Vector3.new(0, -0.5, 0)
local V3_HEAD_OFFSET = Vector3.new(0, 1.5, 0)
local V3_WATER_BOX   = Vector3.new(2, 3.5, 2)
local V3_BOX_CENTRE  = Vector3.new(0, 0.75, 0)
local V3_CREST_UP    = Vector3.new(0, 10, 0)
local V3_CREST_DOWN  = Vector3.new(0, -20, 0)
local CAST_SHRINK_V3 = Vector3.one * CFG.SLIDE_CAST_SHRINK
local TWEEN_BLUR     = TweenInfo.new(CFG.BLUR_TWEEN_TIME)
local V3_BUOYANCY    = Vector3.new(0, CFG.BUBBLE_BUOYANCY, 0)

-- ─── GRADIENT PATTERNS ───────────────────────────────────────────────────────
local ARC_PAIR = NumberSequence.new({
	NumberSequenceKeypoint.new(0,   0),  NumberSequenceKeypoint.new(0.3, 0),
	NumberSequenceKeypoint.new(0.5, 1),  NumberSequenceKeypoint.new(0.7, 0),
	NumberSequenceKeypoint.new(1,   0),
})
local ARC_COMET = NumberSequence.new({
	NumberSequenceKeypoint.new(0,    1),
	NumberSequenceKeypoint.new(0.45, 0.65),
	NumberSequenceKeypoint.new(1,    0),
})
local ARC_CAUSTIC = NumberSequence.new({
	NumberSequenceKeypoint.new(0,    0.0), NumberSequenceKeypoint.new(0.25, 0.6),
	NumberSequenceKeypoint.new(0.5,  0.0), NumberSequenceKeypoint.new(0.75, 0.6),
	NumberSequenceKeypoint.new(1,    0.0),
})
local ARC_BOW = NumberSequence.new({   -- slow, wide soft ring for bow-wave
	NumberSequenceKeypoint.new(0,    0),
	NumberSequenceKeypoint.new(0.15, 0),
	NumberSequenceKeypoint.new(0.5,  1),
	NumberSequenceKeypoint.new(0.85, 0),
	NumberSequenceKeypoint.new(1,    0),
})

-- ─── TYPES ───────────────────────────────────────────────────────────────────
type RingLayer = {
	holder: Frame, core: UIStroke, halo: UIStroke,
	coreGradient: UIGradient, haloGradient: UIGradient,
}
type SurfaceFx = {
	part: Part, gui: SurfaceGui,
	outer: RingLayer, inner: RingLayer, bow: RingLayer,   -- v6: bow ring added
	foam: ParticleEmitter, burstPuffs: ParticleEmitter, burstDrops: ParticleEmitter,
}
type Ripple = {
	part: Part, gui: SurfaceGui, layer: RingLayer,
	active: boolean, born: number, life: number, bias: number,
}
type Streak = { part: Part, trail: Trail, velocity: Vector3, active: boolean }
type Bubble = { pos: Vector3, vel: Vector3, born: number, life: number, active: boolean, part: Part }
type CausticLayer = { frame: Frame, grad: UIGradient, stroke: UIStroke, phase: number, speed: number }
type SpringCfg = { k1: number, k2: number }

-- ─── SPRING UTILITIES ────────────────────────────────────────────────────────
local function makeSpringCfg(omega: number, zeta: number): SpringCfg
	local d = zeta * omega
	return { k1 = 2 * d, k2 = omega * omega }
end
local function springS(val: number, vel: number, target: number, cfg: SpringCfg, dt: number): (number, number)
	dt = math.min(dt, 0.1)
	local acc = -cfg.k2 * (val - target) - cfg.k1 * vel
	vel = vel + acc * dt
	return val + vel * dt, vel
end
local function springV3(val: Vector3, vel: Vector3, target: Vector3, cfg: SpringCfg, dt: number): (Vector3, Vector3)
	dt = math.min(dt, 0.1)
	local err = val - target
	local acc = -cfg.k2 * err - cfg.k1 * vel
	vel = vel + acc * dt
	return val + vel * dt, vel
end
local function springDir(from: Vector3, vel: Vector3, target: Vector3, cfg: SpringCfg, dt: number): (Vector3, Vector3)
	local err    = 1 - math.clamp(from:Dot(target), -1, 1)
	local newMag = math.max(vel.Magnitude + (-cfg.k2 * err - cfg.k1 * vel.Magnitude) * math.min(dt, 0.1), 0)
	local alpha  = math.clamp(1 - math.exp(-math.sqrt(cfg.k2) * dt), 0, 1)
	local mixed  = from:Lerp(target, alpha)
	if mixed.Magnitude < 0.001 then mixed = target end
	return mixed.Unit, Vector3.new(newMag, 0, 0) * math.sign(err)
end
local function expAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * math.min(dt, 0.1))
end
local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

-- ─── BODY PARTS ──────────────────────────────────────────────────────────────
local BODY_PART_NAMES = {
	"Head", "UpperTorso", "LowerTorso", "LeftHand", "RightHand", "LeftFoot", "RightFoot",
	"Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg",
}
local function fitBodyCached(root: BasePart, head: BasePart?, pelvis: BasePart?, limbs: { BasePart }): (CFrame, Vector3)
	local origin = root.Position
	local axis   = root.CFrame.LookVector
	if head and pelvis then
		local spine = head.Position - pelvis.Position
		if spine.Magnitude > 0.5 then axis = spine.Unit end
	end
	local low, high = -1.0, 1.0
	for _, part in limbs do
		local along = (part.Position - origin):Dot(axis)
		low  = math.min(low,  along - 0.5)
		high = math.max(high, along + 0.5)
	end
	local up = V3_UP
	if math.abs(axis:Dot(up)) > 0.98 then up = root.CFrame.RightVector end
	local center = origin + axis * ((low + high) * 0.5)
	local size   = Vector3.new(CFG.BODY_WIDTH, CFG.BODY_THICKNESS, (high - low) + CFG.BODY_LENGTH_PAD * 2)
	return CFrame.lookAt(center, center + axis, up), size
end

-- ─── COLLIDE-AND-SLIDE ───────────────────────────────────────────────────────
local function collideAndSlide(boxCF: CFrame, boxSize: Vector3, velocity: Vector3, dt: number, params: RaycastParams): Vector3
	local castSize  = boxSize - CAST_SHRINK_V3
	local cf        = boxCF
	local remaining = velocity * dt
	local moved     = V3_ZERO
	for _ = 1, CFG.SLIDE_MAX_BOUNCES do
		local distance = remaining.Magnitude
		if distance < 1e-4 then break end
		local direction = remaining / distance
		local hit = Workspace:Blockcast(cf, castSize, direction * (distance + CFG.SLIDE_SKIN), params)
		if not hit then moved += remaining; break end
		local approach = math.max(-direction:Dot(hit.Normal), 0.1)
		local travel   = math.clamp(hit.Distance - CFG.SLIDE_SKIN / approach, 0, distance)
		local step     = direction * travel
		moved += step; cf = cf + step
		local leftover = remaining - step
		remaining = leftover - hit.Normal * leftover:Dot(hit.Normal)
	end
	return moved / dt
end

-- ─── INSTANCE HELPERS ────────────────────────────────────────────────────────
local function newEffectPart(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.Transparency = 1
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false
	p.CanTouch = false; p.CastShadow = false
	return p
end
local function newEmitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter"); local t: any = e
	for k, v in props do t[k] = v end; e.Parent = parent; return e
end
local function newRingGui(part: Part): SurfaceGui
	local g = Instance.new("SurfaceGui")
	g.Name = "RingGui"; g.Face = Enum.NormalId.Top
	g.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	g.CanvasSize = Vector2.new(RING_CANVAS, RING_CANVAS)
	g.LightInfluence = 0; g.AlwaysOnTop = false; g.Active = false
	g.Parent = part; return g
end
local function buildRingLayer(
	parent: Instance, coreThick: number, haloThick: number,
	coreAlpha: number, haloAlpha: number, pattern: NumberSequence
): RingLayer
	local holder = Instance.new("Frame")
	holder.Name = "RingLayer"; holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.new(1, -RING_MARGIN * 2, 1, -RING_MARGIN * 2)
	holder.BackgroundTransparency = 1; holder.BorderSizePixel = 0; holder.Parent = parent
	local function circle(name: string, color: Color3, thick: number, alpha: number): (UIStroke, UIGradient)
		local f = Instance.new("Frame")
		f.Name = name; f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5); f.Size = UDim2.fromScale(1, 1)
		f.BackgroundTransparency = 1; f.BorderSizePixel = 0; f.Parent = holder
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0.5, 0); corner.Parent = f
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = color; stroke.Thickness = thick; stroke.Transparency = alpha; stroke.Parent = f
		local grad = Instance.new("UIGradient"); grad.Transparency = pattern; grad.Parent = stroke
		return stroke, grad
	end
	local halo, haloGrad = circle("Halo", CFG.RING_HALO_COLOR, haloThick, haloAlpha)
	local core, coreGrad = circle("Core", CFG.RING_CORE_COLOR, coreThick, coreAlpha)
	return { holder = holder, core = core, halo = halo, coreGradient = coreGrad, haloGradient = haloGrad }
end

-- ─── RIPPLE POOL ─────────────────────────────────────────────────────────────
local RIPPLE_START_SIZE     = UDim2.fromScale(0.08, 0.08)
local RIPPLE_FULL_SIZE      = UDim2.new(1, -RING_MARGIN * 2, 1, -RING_MARGIN * 2)
local RIPPLE_CORE_ALPHA     = 0.05
local RIPPLE_HALO_ALPHA     = 0.72
local RIPPLE_LAYER_STEP     = 0.004
local RIPPLE_CORE_RANGE     = 1 - RIPPLE_CORE_ALPHA
local RIPPLE_HALO_RANGE     = 1 - RIPPLE_HALO_ALPHA
local RIPPLE_CORE_THICK_RNG = 1 - CFG.RING_CORE_PX
local RIPPLE_HALO_THICK_RNG = 3 - CFG.RING_HALO_PX

local effectsFolder = Instance.new("Folder")
effectsFolder.Name = "SwimEffects"; effectsFolder.Parent = Workspace

local ripplePool: { Ripple } = {}
local rippleLoop: RBXScriptConnection? = nil

local function buildRipple(index: number): Ripple
	local part = newEffectPart("SwimRipple", Vector3.new(8, 0.05, 8))
	local gui  = newRingGui(part); gui.Enabled = false
	local layer = buildRingLayer(gui, CFG.RING_CORE_PX, CFG.RING_HALO_PX, RIPPLE_CORE_ALPHA, RIPPLE_HALO_ALPHA, ARC_PAIR)
	part.Parent = effectsFolder
	return { part = part, gui = gui, layer = layer, active = false, born = 0, life = 1, bias = index * RIPPLE_LAYER_STEP }
end
for i = 1, CFG.RIPPLE_POOL_SIZE do table.insert(ripplePool, buildRipple(i)) end

local function stepRipples()
	local now = os.clock(); local any = false
	for _, r in ripplePool do
		if r.active then
			local t = (now - r.born) / r.life
			if t >= 1 then
				r.active = false; r.gui.Enabled = false
			else
				any = true
				local grow = TweenService:GetValue(t, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
				local fade = TweenService:GetValue(t, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
				local l = r.layer
				l.holder.Size       = RIPPLE_START_SIZE:Lerp(RIPPLE_FULL_SIZE, grow)
				l.core.Transparency = RIPPLE_CORE_ALPHA + RIPPLE_CORE_RANGE     * fade
				l.core.Thickness    = CFG.RING_CORE_PX  + RIPPLE_CORE_THICK_RNG * fade
				l.halo.Transparency = RIPPLE_HALO_ALPHA  + RIPPLE_HALO_RANGE     * fade
				l.halo.Thickness    = CFG.RING_HALO_PX   + RIPPLE_HALO_THICK_RNG * fade
			end
		end
	end
	if not any and rippleLoop then rippleLoop:Disconnect(); rippleLoop = nil end
end

local function spawnRipple(x: number, z: number, sy: number, diameter: number, life: number)
	local now = os.clock()
	local chosen: Ripple? = nil
	for _, c in ripplePool do if not c.active then chosen = c; break end end
	if not chosen then
		local least = math.huge
		for _, c in ripplePool do
			local rem = c.born + c.life - now
			if rem < least then least = rem; chosen = c end
		end
	end
	if not chosen then return end
	local r = chosen
	r.active = true; r.born = now; r.life = life
	r.part.Size   = Vector3.new(diameter, 0.05, diameter)
	r.part.CFrame = CFrame.new(x, sy + CFG.SURFACE_OFFSET + r.bias, z)
	local l = r.layer
	l.holder.Size       = RIPPLE_START_SIZE
	l.core.Transparency = RIPPLE_CORE_ALPHA; l.core.Thickness = CFG.RING_CORE_PX
	l.halo.Transparency = RIPPLE_HALO_ALPHA; l.halo.Thickness = CFG.RING_HALO_PX
	local spin = math.random() * 360
	l.coreGradient.Rotation = spin; l.haloGradient.Rotation = spin
	r.gui.Enabled = true
	if not rippleLoop then rippleLoop = RunService.PreRender:Connect(stepRipples) end
end

-- v6: halve remaining life of all active ripples (called on water exit)
local function fadeAllRipples()
	local now = os.clock()
	for _, r in ripplePool do
		if r.active then
			local elapsed = now - r.born
			local remaining = r.life - elapsed
			if remaining > 0 then
				r.life = elapsed + remaining * 0.5  -- half the remaining time
			end
		end
	end
end

-- ─── CAUSTIC SHIMMER ─────────────────────────────────────────────────────────
local function makeCausticGui(parent: Part): (SurfaceGui, { CausticLayer })
	local gui = Instance.new("SurfaceGui")
	gui.Name = "CausticGui"; gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.LightInfluence = 0; gui.AlwaysOnTop = false; gui.Active = false; gui.Parent = parent
	local layers: { CausticLayer } = {}
	for _ = 1, CFG.CAUSTIC_LAYERS do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5); f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromScale(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5)
		f.BackgroundTransparency = 1; f.BorderSizePixel = 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0.5, 0)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(180, 230, 255); stroke.Thickness = 6 + math.random() * 8
		stroke.Transparency = CFG.CAUSTIC_ALPHA_BASE; stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = f
		local grad = Instance.new("UIGradient")
		grad.Transparency = ARC_CAUSTIC; grad.Rotation = math.random() * 360; grad.Parent = stroke
		f.Parent = gui
		table.insert(layers, {
			frame = f, grad = grad, stroke = stroke,
			phase = math.random() * TAU,
			speed = (CFG.CAUSTIC_SPEED * 0.7 + math.random() * CFG.CAUSTIC_SPEED * 0.6) * (math.random() < 0.5 and 1 or -1),
		})
	end
	return gui, layers
end

-- ─── STREAK CONNECTIONS ───────────────────────────────────────────────────────
local activeStreakConns: { RBXScriptConnection } = {}
local lastSplashClock = 0
local HALF_GRAVITY    = -0.5 * 55

-- ─── 3-D BUBBLE POOL ─────────────────────────────────────────────────────────
local bubblePool: { Bubble } = {}
local bubbleLoopConn: RBXScriptConnection? = nil

local function buildBubbleParts()
	for _ = 1, CFG.BUBBLE_POOL_SIZE do
		local p = newEffectPart("SwimBubble3D", Vector3.new(0.15, 0.15, 0.15))
		p.Shape = Enum.PartType.Ball; p.Material = Enum.Material.Glass
		p.Color = Color3.fromRGB(200, 240, 255); p.Transparency = 0.6; p.Parent = effectsFolder
		table.insert(bubblePool, { pos = V3_ZERO, vel = V3_ZERO, born = 0, life = 0, active = false, part = p })
	end
end
buildBubbleParts()

local function spawnBubble3D(origin: Vector3, swimVel: Vector3)
	for _, b in bubblePool do
		if not b.active then
			b.active = true
			b.pos = origin + Vector3.new((math.random() - 0.5) * 0.6, 0, (math.random() - 0.5) * 0.6)
			b.vel = Vector3.new(
				(math.random() - 0.5) * CFG.BUBBLE_SPREAD + swimVel.X * 0.15,
				math.random() * 1.2 + 0.3,
				(math.random() - 0.5) * CFG.BUBBLE_SPREAD + swimVel.Z * 0.15
			)
			b.born = os.clock(); b.life = math.random() * 0.8 + 0.5
			b.part.CFrame = CFrame.new(b.pos); b.part.Transparency = 0.6
			return
		end
	end
end

local function stepBubbles3D(dt: number)
	local any = false; local now = os.clock()
	for _, b in bubblePool do
		if b.active then
			local age = now - b.born
			if age >= b.life then
				b.active = false
				if b.part.Transparency < 1 then b.part.Transparency = 1 end
			else
				any = true
				b.vel = b.vel + (-b.vel * CFG.BUBBLE_DRAG + V3_BUOYANCY) * dt
				b.pos = b.pos + b.vel * dt
				b.part.CFrame = CFrame.new(b.pos)
				local t = age / b.life
				b.part.Transparency = 0.6 + 0.4 * (t * t)
			end
		end
	end
	if not any and bubbleLoopConn then bubbleLoopConn:Disconnect(); bubbleLoopConn = nil end
end

-- ─── STREAKS (v6: directional bias + depth-scaled width) ─────────────────────
-- v6: swimDir and maxDepth injected so streaks fan forward and scale with depth
local function spawnStreaks(origin: Vector3, count: number, swimDir: Vector3, maxDepth: number)
	local depthT     = math.clamp(maxDepth / CFG.STREAK_DEEP_REF, 0, 1)
	local peakWidth  = CFG.STREAK_WIDTH_BASE + (CFG.STREAK_WIDTH_DEEP - CFG.STREAK_WIDTH_BASE) * depthT
	local streaks: { Streak } = {}

	for i = 1, count do
		local baseAngle = (i / count) * TAU + (math.random() - 0.5) * 0.7
		-- v6: bias the angle toward swimDir in XZ
		local dirAngle  = math.atan2(swimDir.Z, swimDir.X)
		local angle     = baseAngle + (dirAngle - baseAngle) * CFG.STREAK_DIR_BIAS

		local h = 6 + math.random() * 7; local v = 12 + math.random() * 9
		local part = newEffectPart("SplashStreak", Vector3.one * 0.2)
		part.CFrame = CFrame.new(origin)
		local top = Instance.new("Attachment"); top.Position = Vector3.new(0, 0.06, 0); top.Parent = part
		local bot = Instance.new("Attachment"); bot.Position = Vector3.new(0, -0.06, 0); bot.Parent = part
		local trail = Instance.new("Trail")
		trail.Attachment0 = top; trail.Attachment1 = bot
		trail.Lifetime = 0.32; trail.MinLength = 0.05; trail.FaceCamera = true
		trail.LightEmission = 0.8; trail.LightInfluence = 0
		trail.Color       = ColorSequence.new(Color3.fromRGB(255,255,255), CFG.RING_HALO_COLOR)
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
		-- v6: peak width scales with dive depth
		trail.WidthScale  = NumberSequence.new({
			NumberSequenceKeypoint.new(0, peakWidth),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.Parent = part; part.Parent = effectsFolder; Debris:AddItem(part, 1.8)
		table.insert(streaks, {
			part = part, trail = trail,
			velocity = Vector3.new(math.cos(angle) * h, v, math.sin(angle) * h),
			active = true,
		})
	end

	local elapsed = 0; local conn: RBXScriptConnection? = nil
	conn = RunService.PreRender:Connect(function(dt: number)
		elapsed += dt; local any = false
		for _, s in streaks do
			if s.active then
				local gravY = HALF_GRAVITY * elapsed * elapsed
				local pos = origin + s.velocity * elapsed + Vector3.new(0, gravY, 0)
				if pos.Y < origin.Y - 0.1 or elapsed > 1.5 or not s.part.Parent then
					s.active = false; s.trail.Enabled = false
				else
					s.part.CFrame = CFrame.new(pos); any = true
				end
			end
		end
		if not any and conn then
			conn:Disconnect()
			for i, c in activeStreakConns do if c == conn then table.remove(activeStreakConns, i); break end end
			conn = nil
		end
	end)
	if conn then activeStreakConns[#activeStreakConns + 1] = conn end
end

-- ─── SURFACE FX (v6: bow ring added) ─────────────────────────────────────────
local function makeSurfaceFx(): SurfaceFx
	local part = newEffectPart("SwimSurfaceFx", Vector3.new(CFG.SWIRL_DIAMETER, 0.05, CFG.SWIRL_DIAMETER))
	local gui  = newRingGui(part); gui.Enabled = false
	local outer = buildRingLayer(gui, 3, 12, 0.35, 0.82, ARC_COMET)
	local inner = buildRingLayer(gui, 4, 14, 0.12, 0.74, ARC_PAIR)
	inner.holder.Size = UDim2.fromScale(0.6, 0.6)
	-- v6: bow-wave ring — starts at full size, expands outward, slow and subtle
	local bow = buildRingLayer(gui, 2, 8, 1.0, 1.0, ARC_BOW)
	bow.holder.Size = UDim2.fromScale(1.0, 1.0)

	local att = Instance.new("Attachment"); att.Name = "FoamAtt"; att.Parent = part
	local foam = newEmitter(att, {
		Texture = CFG.FOAM_TEXTURE,
		Color   = ColorSequence.new(Color3.fromRGB(250, 253, 255), Color3.fromRGB(165, 215, 248)),
		Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(0.4, 1.9), NumberSequenceKeypoint.new(1, 2.6) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(0.35, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.7, 1.2), Speed = NumberRange.new(0.5, 2.5),
		SpreadAngle = Vector2.new(85, 85), EmissionDirection = Enum.NormalId.Top,
		Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-45, 45),
		Drag = 1.5, LightEmission = 0.2, LightInfluence = 0.3, Rate = 0,
	})
	local burstPuffs = newEmitter(att, {
		Texture = CFG.FOAM_TEXTURE,
		Color   = ColorSequence.new(Color3.fromRGB(252, 254, 255), Color3.fromRGB(170, 218, 250)),
		Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(0.25, 3.2), NumberSequenceKeypoint.new(1, 4.8) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.45, 0.4), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.6, 1.0), Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(48, 48), EmissionDirection = Enum.NormalId.Top,
		Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-60, 60),
		Drag = 5, LightEmission = 0.2, LightInfluence = 0.3, Rate = 0,
	})
	local burstDrops = newEmitter(att, {
		Texture = CFG.DROP_TEXTURE, Color = ColorSequence.new(Color3.fromRGB(235, 248, 255)),
		Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0.1) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.7, 0.3), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.6, 1.1), Speed = NumberRange.new(12, 22),
		SpreadAngle = Vector2.new(28, 28), EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -55, 0), LightEmission = 0.4, Rate = 0,
	})
	part.Parent = effectsFolder
	return { part = part, gui = gui, outer = outer, inner = inner, bow = bow,
	         foam = foam, burstPuffs = burstPuffs, burstDrops = burstDrops }
end

-- ─── TERRAIN SURFACE ─────────────────────────────────────────────────────────
local function findTerrainSurfaceY(position: Vector3): number?
	local layers = 10
	local x = math.floor(position.X / VOXEL) * VOXEL
	local z = math.floor(position.Z / VOXEL) * VOXEL
	local yBase = math.max((math.floor(position.Y / VOXEL) - 2) * VOXEL, 0)
	local region = Region3.new(Vector3.new(x, yBase, z), Vector3.new(x + VOXEL, yBase + layers * VOXEL, z + VOXEL))
	local ok, mats, occs = pcall(function() return Workspace.Terrain:ReadVoxels(region, VOXEL) end)
	if not ok then return nil end
	local col: any = (mats :: any)[1]
	local top = 0
	for i = 1, layers do
		if col[i][1] == Enum.Material.Water then top = i elseif top > 0 then break end
	end
	if top == 0 then return nil end
	return yBase + (top - 1) * VOXEL + (occs :: any)[1][top][1] * VOXEL
end
local function getSurfaceY(root: BasePart, character: Model, waterTop: number?): number?
	if waterTop then return waterTop end
	local ty = findTerrainSurfaceY(root.Position)
	if ty then return ty end
	local p = RaycastParams.new(); p.ExcludeInstances = { character }; p.IgnoreWater = false
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, 80, 0), p)
	if hit and hit.Material == Enum.Material.Water then return hit.Position.Y end
	return nil
end

-- ─── SPLASH (v6: swimDir + maxDepth forwarded to streaks) ────────────────────
local function playSplash(fx: SurfaceFx, x: number, z: number, sy: number, big: boolean, swimDir: Vector3, maxDepth: number)
	local now = os.clock()
	if now - lastSplashClock < 0.5 then return end
	lastSplashClock = now
	local scale = big and 1 or 0.6
	fx.part.CFrame = CFrame.new(x, sy + CFG.SURFACE_OFFSET, z)
	fx.burstPuffs:Emit(math.floor(CFG.SPLASH_PUFFS * scale))
	fx.burstDrops:Emit(math.floor(CFG.SPLASH_DROPS * scale))
	if big then spawnStreaks(Vector3.new(x, sy + 0.25, z), CFG.SPLASH_STREAKS, swimDir, maxDepth) end
	local d = CFG.ENTRY_RING_DIAMETER * scale; local lt = CFG.RIPPLE_TWEEN_TIME
	spawnRipple(x, z, sy, d, lt)
	task.delay(0.10, spawnRipple, x, z, sy, d * 0.75, lt * 0.90)
	task.delay(0.22, spawnRipple, x, z, sy, d * 0.50, lt * 0.80)
	task.delay(0.36, spawnRipple, x, z, sy, d * 0.30, lt * 0.70)
end

-- ─── CLEANUP on script destroy ───────────────────────────────────────────────
script.Destroying:Connect(function()
	if rippleLoop then rippleLoop:Disconnect(); rippleLoop = nil end
	if bubbleLoopConn then bubbleLoopConn:Disconnect(); bubbleLoopConn = nil end
	for _, c in activeStreakConns do c:Disconnect() end; table.clear(activeStreakConns)
	effectsFolder:Destroy()
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  CHARACTER SETUP
-- ═══════════════════════════════════════════════════════════════════════════════
local function SetupCharacter(character: Model)
	local humanoid    = character:WaitForChild("Humanoid") :: Humanoid
	local primaryPart = (character.PrimaryPart or character:WaitForChild("HumanoidRootPart", 5)) :: BasePart
	if not primaryPart then return end
	local animator = humanoid:WaitForChild("Animator") :: Animator
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)

	local att = Instance.new("Attachment"); att.Name = "SwimAtt"; att.Parent = primaryPart
	local linVel = Instance.new("LinearVelocity")
	linVel.Name = "SwimVelocity"; linVel.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linVel.RelativeTo = Enum.ActuatorRelativeTo.World; linVel.Attachment0 = att
	linVel.MaxForce = 0; linVel.Parent = primaryPart
	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = "SwimOri"; alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = att; alignOri.RigidityEnabled = false
	alignOri.MaxTorque = 100000; alignOri.Responsiveness = 30
	alignOri.Enabled = false; alignOri.Parent = primaryPart

	local bubbleEmit = Instance.new("ParticleEmitter")
	bubbleEmit.Texture = "rbxassetid://243660364"
	bubbleEmit.Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(0.5, 0.28), NumberSequenceKeypoint.new(1, 0) })
	bubbleEmit.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.7, 0.5), NumberSequenceKeypoint.new(1, 1) })
	bubbleEmit.LightInfluence = 0.6; bubbleEmit.LightEmission = 0.3
	bubbleEmit.Color = ColorSequence.new(Color3.fromRGB(180,225,255), Color3.fromRGB(255,255,255))
	bubbleEmit.Lifetime = NumberRange.new(0.7, 1.5); bubbleEmit.Rate = 0
	bubbleEmit.Speed = NumberRange.new(1.5, 4); bubbleEmit.Rotation = NumberRange.new(0, 360)
	bubbleEmit.RotSpeed = NumberRange.new(-90, 90); bubbleEmit.SpreadAngle = Vector2.new(30, 30)
	bubbleEmit.EmissionDirection = Enum.NormalId.Top; bubbleEmit.Enabled = true; bubbleEmit.Parent = primaryPart

	local wakeEmit = Instance.new("ParticleEmitter")
	wakeEmit.Texture = "rbxassetid://243660364"
	wakeEmit.Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	wakeEmit.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	wakeEmit.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255)); wakeEmit.Lifetime = NumberRange.new(0.3, 0.6)
	wakeEmit.Rate = 0; wakeEmit.Speed = NumberRange.new(0.5, 2); wakeEmit.SpreadAngle = Vector2.new(80, 80)
	wakeEmit.EmissionDirection = Enum.NormalId.Top; wakeEmit.Enabled = true; wakeEmit.Parent = primaryPart

	local surfaceFx  = makeSurfaceFx()
	local causticPart = newEffectPart("SwimCaustic", Vector3.new(20, 0.05, 20)); causticPart.Parent = effectsFolder
	local causticGui, causticLayers = makeCausticGui(causticPart); causticGui.Enabled = false

	local hitbox = newEffectPart("SwimHitbox", Vector3.new(CFG.BODY_WIDTH, CFG.BODY_THICKNESS, 5))
	hitbox.Material = Enum.Material.Neon; hitbox.Color = Color3.fromRGB(80, 200, 255)
	hitbox.Transparency = (CFG.SHOW_HITBOX and IS_STUDIO) and 0.75 or 1
	hitbox:SetAttribute("OwnerUserId", tostring(LocalPlayer.UserId)); hitbox:SetAttribute("Swimming", false)
	CollectionService:AddTag(hitbox, "SwimHitbox"); hitbox.Parent = effectsFolder

	local blurFx = Instance.new("BlurEffect"); blurFx.Name = "SwimBlur"; blurFx.Size = 0; blurFx.Enabled = false
	local colorFx = Instance.new("ColorCorrectionEffect"); colorFx.Name = "SwimCC"
	colorFx.TintColor = Color3.fromRGB(255,255,255); colorFx.Brightness = 0
	colorFx.Contrast = 0; colorFx.Saturation = 0; colorFx.Enabled = false

	local savedFogEnd   = Lighting.FogEnd
	local savedFogColor = Lighting.FogColor
	local currentFogEnd = savedFogEnd

	local wop = OverlapParams.new(); wop.FilterType = Enum.RaycastFilterType.Include; wop.MaxParts = 32
	local castP = RaycastParams.new()
	castP.IgnoreWater = true; castP.RespectCanCollide = true; castP.CollisionGroup = primaryPart.CollisionGroup
	local crestParams = RaycastParams.new(); crestParams.IgnoreWater = false

	local conns: { RBXScriptConnection } = {}
	local renderConn: RBXScriptConnection?
	local visualConn: RBXScriptConnection?
	local hitboxConn: RBXScriptConnection?

	local function RefreshWaterFilter()
		local tagged = CollectionService:GetTagged("Water")
		wop.FilterDescendantsInstances = tagged
		local ignore = table.clone(tagged)
		table.insert(ignore, character); table.insert(ignore, effectsFolder)
		castP.ExcludeInstances = ignore; crestParams.ExcludeInstances = { character }
	end
	table.insert(conns, CollectionService:GetInstanceAddedSignal("Water"):Connect(RefreshWaterFilter))
	table.insert(conns, CollectionService:GetInstanceRemovedSignal("Water"):Connect(RefreshWaterFilter))
	RefreshWaterFilter()

	-- spring configs
	local sprVel  = makeSpringCfg(math.sqrt(CFG.VEL_STIFFNESS), CFG.VEL_DAMPING / (2 * math.sqrt(CFG.VEL_STIFFNESS)))
	local sprOri  = makeSpringCfg(CFG.ORI_OMEGA,      CFG.ORI_ZETA)
	local sprTilt = makeSpringCfg(CFG.TILT_OMEGA,     CFG.TILT_ZETA)
	local sprBank = makeSpringCfg(CFG.BANK_OMEGA,     CFG.BANK_ZETA)
	local sprLean = makeSpringCfg(CFG.CAM_LEAN_OMEGA, CFG.CAM_LEAN_ZETA)

	-- ── state ─────────────────────────────────────────────────────────────────
	local isUnderwater  = false
	local isRising      = false
	local isSinking     = false
	local wasUnderwater = false
	local isCleanedUp   = false

	local curVel      = V3_ZERO; local velSpringV  = V3_ZERO
	local smoothLook  = primaryPart.CFrame.LookVector; local lookSpringV = V3_ZERO
	local curTilt  = 0.0; local tiltVelS = 0.0
	local curBank  = 0.0; local bankVelS = 0.0
	local curLean  = 0.0; local leanVelS = 0.0

	local lastWaterTop: number? = nil
	local surfaceY: number?     = nil
	local shownSurfaceY         = 0.0
	local surfaceReady          = false
	local surfaceTimer          = 0.0
	local wakeTimer             = 0.0
	local fxAlpha               = 0.0
	local swirlTime             = 0.0
	local movingNow             = false
	local swirlPosX             = 0.0
	local swirlPosZ             = 0.0
	local swirlReady            = false
	local swimDepth             = 0.0
	local swimClock             = 0.0
	local prevCrestY            = 0.0
	local crestTimer            = 0.0
	local bubbleAccum           = 0.0
	local lastBubbleRate        = -1.0
	local lastWakeRate          = -1.0

	-- v6 state
	local diveStartTime     = 0.0
	local maxDepthReached   = 0.0
	local diveDist          = 0.0
	local diveStartPos      = V3_ZERO
	local breathTime        = 0.0       -- accumulates for BOB_FREQ
	local bowWaveAge        = 0.0       -- time since bow wave started
	local bowWaveActive     = false
	local foamColorTimer    = 0.0       -- throttle for foam ColorSequence writes
	local lastFoamSf        = -1.0      -- last sf used to write foam colour
	local distortTime       = 0.0       -- accumulates for DISTORT_FREQ

	local cachedHead:   BasePart? = nil
	local cachedPelvis: BasePart? = nil
	local cachedLimbs:  { BasePart } = {}

	local function RebuildBodyCache()
		cachedHead = nil; cachedPelvis = nil; table.clear(cachedLimbs)
		local h = character:FindFirstChild("Head")
		local p = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
		if h and h:IsA("BasePart") then cachedHead = h end
		if p and p:IsA("BasePart") then cachedPelvis = p end
		for _, name in BODY_PART_NAMES do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then table.insert(cachedLimbs, part :: BasePart) end
		end
	end

	local swimIdleAnim: AnimationTrack?
	local swimMoveAnim: AnimationTrack?
	local currentAnim:  AnimationTrack?

	task.spawn(function()
		local aScript = character:WaitForChild("Animate", 5)
		if isCleanedUp or humanoid.Health <= 0 then return end
		local idleObj = aScript and (aScript:FindFirstChild("SwimIdle", true) or aScript:FindFirstChild("swimidle", true))
		local moveObj = aScript and (aScript:FindFirstChild("Swim",     true) or aScript:FindFirstChild("swim",     true))
		local idleInst = Instance.new("Animation")
		idleInst.AnimationId = (idleObj and idleObj:IsA("Animation") and idleObj.AnimationId ~= "") and idleObj.AnimationId or CFG.FALLBACK_IDLE_ANIM
		local moveInst = Instance.new("Animation")
		moveInst.AnimationId = (moveObj and moveObj:IsA("Animation") and moveObj.AnimationId ~= "") and moveObj.AnimationId or CFG.FALLBACK_SWIM_ANIM
		local ok1, ldIdle = pcall(function() return animator:LoadAnimation(idleInst) end)
		local ok2, ldMove = pcall(function() return animator:LoadAnimation(moveInst) end)
		if isCleanedUp or humanoid.Health <= 0 then
			if ok1 then (ldIdle :: AnimationTrack):Destroy() end
			if ok2 then (ldMove :: AnimationTrack):Destroy() end
			return
		end
		if ok1 then local t = ldIdle :: AnimationTrack; t.Priority = Enum.AnimationPriority.Action3; swimIdleAnim = t end
		if ok2 then local t = ldMove :: AnimationTrack; t.Priority = Enum.AnimationPriority.Action3; swimMoveAnim = t end
	end)

	local function CheckIsUnderwater(): boolean
		local pos = primaryPart.Position
		local sy = surfaceY
		if sy and pos.Y < sy - 0.5 then return true end
		local terrain = Workspace.Terrain
		if terrain:GetMaterialAtPosition(pos) == Enum.Material.Water then lastWaterTop = nil; return true end
		if terrain:GetMaterialAtPosition(pos + V3_HEAD_OFFSET) == Enum.Material.Water then lastWaterTop = nil; return true end
		local parts = Workspace:GetPartBoundsInBox(CFrame.new(pos + V3_BOX_CENTRE), V3_WATER_BOX, wop)
		if #parts == 0 then lastWaterTop = nil; return false end
		local top = -math.huge
		for _, p in parts do top = math.max(top, p.Position.Y + p.Size.Y * 0.5) end
		lastWaterTop = top; return true
	end

	local function MeasureSurface(): number?
		local y = getSurfaceY(primaryPart, character, lastWaterTop)
		if y then
			surfaceY = y
			if not surfaceReady then surfaceReady = true; shownSurfaceY = y end
		end
		return y
	end

	local function HandleAnimation(moving: boolean)
		local desired = moving and swimMoveAnim or swimIdleAnim
		if desired and desired ~= currentAnim then
			if currentAnim then currentAnim:Stop(0.2) end
			currentAnim = desired; desired:Play(0.2)
		end
	end

	local function OnRiseAction(_, state: Enum.UserInputState)
		if isUnderwater then isRising = state == Enum.UserInputState.Begin; return Enum.ContextActionResult.Sink end
		isRising = false; return Enum.ContextActionResult.Pass
	end
	local function OnSinkAction(_, state: Enum.UserInputState)
		if isUnderwater then isSinking = state == Enum.UserInputState.Begin; return Enum.ContextActionResult.Sink end
		isSinking = false; return Enum.ContextActionResult.Pass
	end
	local function UnbindInputs()
		ContextActionService:UnbindAction(BIND_RISE); ContextActionService:UnbindAction(BIND_SINK)
		isRising = false; isSinking = false
	end
	local function BindInputs()
		UnbindInputs()
		ContextActionService:BindAction(BIND_RISE, OnRiseAction, false, Enum.KeyCode.Space,     Enum.KeyCode.ButtonA)
		ContextActionService:BindAction(BIND_SINK, OnSinkAction, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonB)
	end

	local function ApplyUnderwaterFX(camera: Camera)
		blurFx.Enabled = true; colorFx.Enabled = true
		blurFx.Parent = camera; colorFx.Parent = camera
		TweenService:Create(blurFx,   TWEEN_BLUR, { Size = CFG.BLUR_SIZE }):Play()
		TweenService:Create(colorFx,  TWEEN_BLUR, { TintColor = CFG.UNDERWATER_FOG_COLOR, Brightness = -0.04, Saturation = -0.15 }):Play()
		TweenService:Create(Lighting, TWEEN_BLUR, { FogEnd = CFG.UNDERWATER_FOG_END, FogColor = CFG.UNDERWATER_FOG_COLOR }):Play()
		currentFogEnd = CFG.UNDERWATER_FOG_END
	end
	local function RemoveUnderwaterFX()
		TweenService:Create(blurFx,   TWEEN_BLUR, { Size = 0 }):Play()
		TweenService:Create(colorFx,  TWEEN_BLUR, { TintColor = Color3.fromRGB(255,255,255), Brightness = 0, Saturation = 0 }):Play()
		TweenService:Create(Lighting, TWEEN_BLUR, { FogEnd = savedFogEnd, FogColor = savedFogColor }):Play()
		currentFogEnd = savedFogEnd
		task.delay(CFG.BLUR_TWEEN_TIME + 0.05, function() blurFx.Enabled = false; colorFx.Enabled = false end)
	end

	local function Cleanup()
		if isCleanedUp then return end; isCleanedUp = true
		UnbindInputs()
		if renderConn then renderConn:Disconnect(); renderConn = nil end
		if visualConn then visualConn:Disconnect(); visualConn = nil end
		if hitboxConn then hitboxConn:Disconnect(); hitboxConn = nil end
		for _, c in activeStreakConns do c:Disconnect() end; table.clear(activeStreakConns)
		for _, c in conns do c:Disconnect() end; table.clear(conns)
		if bubbleLoopConn then bubbleLoopConn:Disconnect(); bubbleLoopConn = nil end
		RemoveUnderwaterFX()
		humanoid.AutoRotate = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming,  true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping,   true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall,  true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		if currentAnim  then currentAnim:Stop(0.1) end
		if swimIdleAnim then swimIdleAnim:Stop(0); swimIdleAnim:Destroy() end
		if swimMoveAnim then swimMoveAnim:Stop(0); swimMoveAnim:Destroy() end
		currentAnim = nil; swimIdleAnim = nil; swimMoveAnim = nil
		linVel:Destroy(); alignOri:Destroy(); bubbleEmit:Destroy(); wakeEmit:Destroy(); att:Destroy()
		surfaceFx.part:Destroy(); causticPart:Destroy(); hitbox:Destroy()
		table.clear(cachedLimbs)
		task.delay(CFG.BLUR_TWEEN_TIME + 0.1, function() blurFx:Destroy(); colorFx:Destroy() end)
	end

	-- ════════════════════════════════════════════════════════════════════════
	--  PHYSICS LOOP
	-- ════════════════════════════════════════════════════════════════════════
	renderConn = RunService.PreSimulation:Connect(function(dt: number)
		if isCleanedUp or not character.Parent or humanoid.Health <= 0 then Cleanup(); return end
		local camera = Workspace.CurrentCamera; if not camera then return end

		isUnderwater = CheckIsUnderwater()

		if isUnderwater then
			if humanoid:GetStateEnabled(Enum.HumanoidStateType.Swimming) then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
			end

			if not wasUnderwater then
				wasUnderwater = true
				BindInputs(); ApplyUnderwaterFX(camera)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping,   false)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall,  false)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
				smoothLook = primaryPart.CFrame.LookVector
				lookSpringV = V3_ZERO; velSpringV = V3_ZERO
				swimClock = 0; lastBubbleRate = -1; lastWakeRate = -1

				-- v6: preserve XZ momentum fully, only clamp Y
				local carried = primaryPart.AssemblyLinearVelocity
				local clampedY = math.max(math.min(carried.Y, CFG.ENTRY_MAX_SPEED), -CFG.ENTRY_MAX_SPEED)
				curVel = Vector3.new(carried.X, clampedY, carried.Z)
				if curVel.Magnitude > CFG.ENTRY_MAX_SPEED then
					curVel = curVel.Unit * CFG.ENTRY_MAX_SPEED
				end

				local eS = MeasureSurface(); surfaceTimer = CFG.SURFACE_TIMER_FAR
				if eS and eS - primaryPart.Position.Y < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position
					playSplash(surfaceFx, p.X, p.Z, eS, true, smoothLook, 0)
				end
				prevCrestY = surfaceY or primaryPart.Position.Y
				RebuildBodyCache()

				-- v6: reset per-dive stats
				diveStartTime   = os.clock()
				maxDepthReached = 0
				diveDist        = 0
				diveStartPos    = primaryPart.Position
				breathTime      = 0
			end

			-- v6: adaptive surface re-check rate
			surfaceTimer -= dt
			if surfaceTimer <= 0 then
				local sy0 = surfaceY
				MeasureSurface()
				-- tighten interval near surface
				surfaceTimer = (sy0 and (sy0 - primaryPart.Position.Y) < CFG.SURFACE_NEAR_DIST)
					and CFG.SURFACE_TIMER_NEAR or CFG.SURFACE_TIMER_FAR
			end

			humanoid.AutoRotate = false; alignOri.Enabled = true; linVel.MaxForce = 100000

			local moveDir  = humanoid.MoveDirection
			local isMoving = moveDir.Magnitude > 0.05
			local targetVel: Vector3

			if isMoving then
				local camCF = camera.CFrame; local rVec = camCF.RightVector
				local fRight = Vector3.new(rVec.X, 0, rVec.Z)
				if fRight.Magnitude > 0.001 then
					local fFwd    = V3_UP:Cross(fRight).Unit
					local yawCF   = CFrame.lookAt(V3_ZERO, fFwd)
					local localIn = yawCF:VectorToObjectSpace(moveDir)
					local swimDir = camCF:VectorToWorldSpace(localIn)
					targetVel = swimDir.Magnitude > 0.001 and swimDir.Unit * CFG.SWIM_SPEED or V3_ZERO
				else
					targetVel = V3_ZERO
				end
			else
				targetVel = V3_SINK_IDLE
			end

			if isRising  then targetVel = Vector3.new(targetVel.X,  CFG.RISE_SPEED, targetVel.Z) end
			if isSinking then targetVel = Vector3.new(targetVel.X, -CFG.SINK_SPEED, targetVel.Z) end

			-- current drift
			local t = os.clock()
			local depthFactor = math.clamp(swimDepth / CFG.CURRENT_DEPTH_SCALE, 0, 1)
			targetVel = targetVel + Vector3.new(
				math.sin(t * TAU * CFG.CURRENT_FREQ_X) * CFG.CURRENT_STRENGTH * depthFactor,
				0,
				math.cos(t * TAU * CFG.CURRENT_FREQ_Z) * CFG.CURRENT_STRENGTH * depthFactor
			)

			-- v6: dynamic surface buoyancy — gentle upward push near surface
			local sy = surfaceY
			if sy and not isSinking then
				local distToSurface = sy - primaryPart.Position.Y
				if distToSurface > 0 and distToSurface < CFG.BUOY_DEPTH then
					local buoyPush = (1 - distToSurface / CFG.BUOY_DEPTH) * CFG.BUOY_STRENGTH
					targetVel = Vector3.new(targetVel.X, targetVel.Y + buoyPush, targetVel.Z)
				end
			end

			-- v6: breath-cycle bob at surface while idle
			if sy and not isMoving and not isRising and not isSinking then
				local depth = sy - primaryPart.Position.Y
				if depth < CFG.BUOY_DEPTH * 2 then
					breathTime += dt
					local speedFactor = math.clamp(curVel.Magnitude / CFG.SWIM_SPEED, 0, 1)
					local bobFade = 1 - math.clamp(speedFactor / CFG.BOB_SPEED_FADE, 0, 1)
					local bob = math.sin(breathTime * TAU * CFG.BOB_FREQ) * CFG.BOB_AMPLITUDE * bobFade
					targetVel = Vector3.new(targetVel.X, targetVel.Y + bob, targetVel.Z)
				end
			end

			-- velocity spring (fixed tick)
			swimClock += math.min(dt, 0.25)
			local ticks = 0
			while swimClock >= SWIM_TICK and ticks < CFG.MAX_TICKS_PER_FRAME do
				swimClock -= SWIM_TICK; ticks += 1
				curVel, velSpringV = springV3(curVel, velSpringV, targetVel, sprVel, SWIM_TICK)
			end
			if ticks == CFG.MAX_TICKS_PER_FRAME then swimClock = 0 end

			-- look direction spring
			local lookTarget = smoothLook
			local applyManualTilt = false
			if isMoving and targetVel.Magnitude > 0.1 then
				lookTarget = targetVel.Unit
			else
				local flat = Vector3.new(primaryPart.CFrame.LookVector.X, 0, primaryPart.CFrame.LookVector.Z)
				if flat.Magnitude > 0.001 then lookTarget = flat.Unit end
				applyManualTilt = true
			end
			smoothLook, lookSpringV = springDir(smoothLook, lookSpringV, lookTarget, sprOri, dt)

			-- tilt spring
			local normY = math.clamp(curVel.Y / CFG.RISE_SPEED, -1, 1)
			local targetTilt = applyManualTilt and (-normY * CFG.TILT_MAX) or (-normY * CFG.TILT_MAX * 0.5)
			curTilt, tiltVelS = springS(curTilt, tiltVelS, targetTilt, sprTilt, dt)

			-- bank spring
			local cross = smoothLook:Cross(lookTarget)
			local bankSign = cross.Y > 0 and 1 or -1
			local targetBank = bankSign * math.clamp(cross.Magnitude * 80, 0, CFG.BANK_MAX)
			curBank, bankVelS = springS(curBank, bankVelS, targetBank, sprBank, dt)

			-- collide-and-slide
			if curVel.Magnitude > 0.05 then
				local bCF, bSize = fitBodyCached(primaryPart, cachedHead, cachedPelvis, cachedLimbs)
				curVel = collideAndSlide(bCF, bSize, curVel, math.clamp(dt, 1/240, 1/20), castP)
			end
			linVel.VectorVelocity = curVel

			-- emitter rates
			local speed = math.max(curVel.Magnitude, 0)
			local sf    = math.clamp(speed / CFG.SWIM_SPEED, 0, 1)
			local newBR = math.clamp(CFG.BUBBLE_RATE + (CFG.BUBBLE_MOVE_RATE - CFG.BUBBLE_RATE) * sf, 0, CFG.BUBBLE_MOVE_RATE)
			local newWR = isMoving and math.clamp(sf * 24, 0, 24) or 0
			if math.abs(newBR - lastBubbleRate) > 0.25 then bubbleEmit.Rate = newBR; lastBubbleRate = newBR end
			if math.abs(newWR - lastWakeRate)   > 0.25 then wakeEmit.Rate   = newWR; lastWakeRate   = newWR end

			-- v6: foam rate moved here (one frame earlier, already have sf)
			surfaceFx.foam.Rate = movingNow and (CFG.FOAM_RATE * sf * fxAlpha) or 0

			-- 3-D bubble spawn
			bubbleAccum += dt * (CFG.BUBBLE_RATE * 0.3 + sf * CFG.BUBBLE_RATE * 0.7)
			while bubbleAccum >= 1 do bubbleAccum -= 1; spawnBubble3D(primaryPart.Position, curVel) end
			if not bubbleLoopConn then bubbleLoopConn = RunService.PreRender:Connect(stepBubbles3D) end

			-- multi-layer wake turbulence
			movingNow = isMoving
			wakeTimer -= dt
			if isMoving and sy and wakeTimer <= 0 and (sy - primaryPart.Position.Y) < CFG.SURFACE_FX_DEPTH * 0.6 then
				wakeTimer = CFG.WAKE_RING_INTERVAL * (1.5 - sf * 0.75)
				local p = primaryPart.Position
				local right = Vector3.new(smoothLook.Z, 0, -smoothLook.X).Unit
				for lane = -1, 1 do
					local offset = right * (lane * CFG.WAKE_LANE_WIDTH)
					local diam   = CFG.WAKE_RING_DIAMETER * (1 + (math.random() - 0.5) * CFG.WAKE_DIAM_VARIANCE)
					local life   = CFG.RIPPLE_TWEEN_TIME  * 0.9 * (1 + (math.random() - 0.5) * CFG.WAKE_LIFE_VARIANCE)
					spawnRipple(p.X + offset.X, p.Z + offset.Z, sy, diam, life)
				end
			end

			-- crest detection
			crestTimer -= dt
			if sy and crestTimer <= 0 and isMoving then
				crestTimer = 0.18
				local ahead = primaryPart.Position + smoothLook * CFG.CREST_CHECK_DIST
				local chit  = Workspace:Raycast(ahead + V3_CREST_UP, V3_CREST_DOWN, crestParams)
				if chit and chit.Material == Enum.Material.Water then
					local crY = chit.Position.Y
					if crY - prevCrestY > CFG.CREST_RING_THRESH then
						spawnRipple(ahead.X, ahead.Z, crY, CFG.WAKE_RING_DIAMETER * 1.4, CFG.RIPPLE_TWEEN_TIME * 0.7)
					end
					prevCrestY = crY
				end
			end

			-- v6: per-dive stats tracking
			swimDepth = sy and math.max(sy - primaryPart.Position.Y, 0) or swimDepth
			if swimDepth > maxDepthReached then maxDepthReached = swimDepth end
			diveDist = (primaryPart.Position - diveStartPos).Magnitude

			-- v6: bow-wave activation
			if sf > CFG.BOW_WAVE_THRESHOLD and not bowWaveActive then
				bowWaveActive = true; bowWaveAge = 0
			elseif sf <= CFG.BOW_WAVE_THRESHOLD then
				bowWaveActive = false
			end

			-- orientation
			local rVec2 = camera.CFrame.RightVector
			local upVec = rVec2:Cross(smoothLook)
			upVec = upVec.Magnitude > 0.001 and upVec.Unit or V3_UP
			alignOri.CFrame = CFrame.lookAt(V3_ZERO, smoothLook, upVec)
				* CFrame.Angles(math.rad(curTilt), 0, math.rad(curBank))

			HandleAnimation(isMoving or isRising or isSinking)

		else
			if wasUnderwater then
				wasUnderwater = false
				local wasRising = isRising
				local exitVel   = curVel     -- v6: capture velocity before zeroing
				UnbindInputs()
				humanoid.AutoRotate = true; alignOri.Enabled = false
				if lastBubbleRate ~= 0 then bubbleEmit.Rate = 0; lastBubbleRate = 0 end
				if lastWakeRate   ~= 0 then wakeEmit.Rate   = 0; lastWakeRate   = 0 end
				surfaceFx.foam.Rate = 0
				curTilt = 0; curBank = 0; curLean = 0
				linVel.MaxForce = 0; linVel.VectorVelocity = V3_ZERO; curVel = V3_ZERO
				velSpringV = V3_ZERO; lookSpringV = V3_ZERO
				if currentAnim then currentAnim:Stop(0.2) end; currentAnim = nil
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming,  true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping,   true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall,  true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
				RemoveUnderwaterFX()

				-- v6: write per-dive stats to hitbox attributes for server scripts
				hitbox:SetAttribute("DiveTime",  os.clock() - diveStartTime)
				hitbox:SetAttribute("MaxDepth",  maxDepthReached)
				hitbox:SetAttribute("DiveDist",  diveDist)

				local exitSY = MeasureSurface() or surfaceY
				if exitSY and math.abs(exitSY - primaryPart.Position.Y) < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position
					playSplash(surfaceFx, p.X, p.Z, exitSY, false, smoothLook, maxDepthReached)
				end

				-- v6: fade active ripples quickly
				fadeAllRipples()

				surfaceY = nil; surfaceReady = false; movingNow = false; swimDepth = 0
				bowWaveActive = false; bowWaveAge = 0; breathTime = 0
				table.clear(cachedLimbs); cachedHead = nil; cachedPelvis = nil

				if wasRising then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					-- v6: predictive exit arc — preserve XZ velocity from curVel at moment of exit
					local exitXZ = Vector3.new(exitVel.X, 0, exitVel.Z)
					primaryPart.AssemblyLinearVelocity = exitXZ + Vector3.new(
						0, CFG.RISE_SPEED + CFG.EXIT_JUMP_BONUS, 0
					)
				end
			end
		end
	end)

	-- ════════════════════════════════════════════════════════════════════════
	--  VISUAL LOOP
	-- ════════════════════════════════════════════════════════════════════════
	visualConn = RunService.PreRender:Connect(function(dt: number)
		if isCleanedUp then return end
		local camera = Workspace.CurrentCamera; if not camera then return end
		local sy = surfaceY

		local alpha10   = expAlpha(10,                    dt)
		local alpha20   = expAlpha(20,                    dt)
		local alphaSwrl = expAlpha(CFG.SWIRL_FOLLOW_RATE, dt)
		local alphaFog  = expAlpha(CFG.FOG_ADAPT_RATE,    dt)

		local targetAlpha = 0
		if isUnderwater and sy then
			local depth = sy - primaryPart.Position.Y
			targetAlpha = 1 - math.clamp(
				(depth - CFG.SURFACE_FX_FULL_DEPTH) / (CFG.SURFACE_FX_DEPTH - CFG.SURFACE_FX_FULL_DEPTH),
				0, 1
			)
			-- depth fog
			local depthT  = math.clamp(depth / (CFG.SURFACE_FX_DEPTH * 2), 0, 1)
			local fogTgt  = CFG.UNDERWATER_FOG_END * (1 - CFG.FOG_DEPTH_SCALE * depthT)
			currentFogEnd = currentFogEnd + (fogTgt - currentFogEnd) * alphaFog
			Lighting.FogEnd = currentFogEnd

			-- v6: screen-space distortion pulse (brightness oscillation tied to speed)
			distortTime += dt
			local sf2 = math.clamp(curVel.Magnitude / CFG.SWIM_SPEED, 0, 1)
			local distort = math.sin(distortTime * TAU * CFG.DISTORT_FREQ) * CFG.DISTORT_AMPLITUDE * sf2
			colorFx.Brightness = -0.04 + distort   -- base brightness -0.04 from entry tween
		end
		fxAlpha += (targetAlpha - fxAlpha) * alpha10

		-- camera lean
		local lateralSpeed = 0
		if isUnderwater then lateralSpeed = curVel:Dot(camera.CFrame.RightVector) end
		local targetLean = math.clamp(lateralSpeed / CFG.SWIM_SPEED, -1, 1) * CFG.CAM_LEAN_MAX
		curLean, leanVelS = springS(curLean, leanVelS, targetLean, sprLean, dt)
		if isUnderwater and math.abs(curLean) > 0.01 then
			camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, math.rad(-curLean))
		end

		if not sy or fxAlpha < 0.01 then
			if surfaceFx.gui.Enabled then surfaceFx.gui.Enabled = false end
			if causticGui.Enabled    then causticGui.Enabled    = false end
			swirlReady = false; return
		end
		if not surfaceFx.gui.Enabled then surfaceFx.gui.Enabled = true end

		shownSurfaceY += (sy - shownSurfaceY) * alpha20
		local pos = primaryPart.Position
		if swirlReady then
			swirlPosX += (pos.X - swirlPosX) * alphaSwrl
			swirlPosZ += (pos.Z - swirlPosZ) * alphaSwrl
		else
			swirlPosX = pos.X; swirlPosZ = pos.Z; swirlReady = true
		end
		surfaceFx.part.CFrame = CFrame.new(swirlPosX, shownSurfaceY + CFG.SURFACE_OFFSET, swirlPosZ)

		-- swirl rings
		swirlTime += dt
		local outerSpin = (swirlTime * CFG.SWIRL_SPEED) % 360
		local innerSpin = (-swirlTime * CFG.SWIRL_SPEED * 1.35) % 360
		surfaceFx.outer.coreGradient.Rotation = outerSpin; surfaceFx.outer.haloGradient.Rotation = outerSpin
		surfaceFx.inner.coreGradient.Rotation = innerSpin; surfaceFx.inner.haloGradient.Rotation = innerSpin

		local sf = math.clamp(curVel.Magnitude / CFG.SWIM_SPEED, 0, 1)
		local coreCol = lerpColor(CFG.RING_CORE_COLOR, CFG.RING_CORE_COLOR_FAST, sf)
		local haloCol = lerpColor(CFG.RING_HALO_COLOR, CFG.RING_HALO_COLOR_FAST, sf)
		surfaceFx.outer.core.Color = coreCol; surfaceFx.outer.halo.Color = haloCol
		surfaceFx.inner.core.Color = coreCol; surfaceFx.inner.halo.Color = haloCol

		local breathe = 0.6 + 0.035 * math.sin(swirlTime * 2.4)
		surfaceFx.inner.holder.Size = UDim2.fromScale(breathe, breathe)

		local a = fxAlpha
		surfaceFx.outer.core.Transparency = 1 - 0.65 * a; surfaceFx.outer.halo.Transparency = 1 - 0.18 * a
		surfaceFx.inner.core.Transparency = 1 - 0.88 * a; surfaceFx.inner.halo.Transparency = 1 - 0.26 * a

		-- v6: bow-wave expansion ring
		if bowWaveActive or bowWaveAge > 0 then
			bowWaveAge += dt
			local bowT = math.clamp(bowWaveAge / CFG.BOW_WAVE_EXPAND_TIME, 0, 1)
			local bowScale = 1 + (CFG.BOW_WAVE_SCALE - 1) * bowT
			surfaceFx.bow.holder.Size = UDim2.fromScale(bowScale, bowScale)
			-- fade in at start, fade out toward end of expansion
			local bowFade = bowWaveActive
				and (1 - math.clamp((bowT - 0.6) / 0.4, 0, 1))
				or  (1 - math.clamp(bowWaveAge / 0.4, 0, 1))
			surfaceFx.bow.core.Transparency = 1 - 0.45 * bowFade * a
			surfaceFx.bow.halo.Transparency = 1 - 0.12 * bowFade * a
			surfaceFx.bow.coreGradient.Rotation = (outerSpin * 0.4) % 360
			surfaceFx.bow.haloGradient.Rotation = (outerSpin * 0.4) % 360
			if not bowWaveActive and bowWaveAge > CFG.BOW_WAVE_EXPAND_TIME + 0.4 then
				bowWaveAge = 0  -- fully faded; reset
			end
		else
			surfaceFx.bow.core.Transparency = 1
			surfaceFx.bow.halo.Transparency = 1
		end

		-- v6: speed-adaptive foam color (throttled to avoid per-frame GC)
		foamColorTimer += dt
		if foamColorTimer >= CFG.FOAM_COLOR_INTERVAL and math.abs(sf - lastFoamSf) > 0.06 then
			foamColorTimer = 0; lastFoamSf = sf
			local fc = lerpColor(CFG.FOAM_COLOR_SLOW, CFG.FOAM_COLOR_FAST, sf)
			surfaceFx.foam.Color = ColorSequence.new(fc, lerpColor(fc, Color3.fromRGB(200,230,255), 0.4))
		end

		-- caustic shimmer
		if swimDepth > 1.0 then
			if not causticGui.Enabled then causticGui.Enabled = true end
			causticPart.CFrame = CFrame.new(pos.X, shownSurfaceY - 3.5, pos.Z)
			local daf = 1 - a * 0.3
			for _, layer in causticLayers do
				local ang = (swirlTime * layer.speed + layer.phase) % TAU
				layer.grad.Rotation = math.deg(ang)
				layer.stroke.Transparency = math.clamp(
					(CFG.CAUSTIC_ALPHA_BASE + CFG.CAUSTIC_ALPHA_PULSE * math.sin(ang * 3.1)) * daf, 0, 1
				)
			end
		else
			if causticGui.Enabled then causticGui.Enabled = false end
		end
	end)

	-- ════════════════════════════════════════════════════════════════════════
	--  HITBOX LOOP
	-- ════════════════════════════════════════════════════════════════════════
	hitboxConn = RunService.PostSimulation:Connect(function()
		if isCleanedUp then return end
		if isUnderwater then
			local bCF, bSize = fitBodyCached(primaryPart, cachedHead, cachedPelvis, cachedLimbs)
			hitbox.CFrame = bCF; hitbox.Size = bSize
			if not hitbox.CanQuery then hitbox.CanQuery = true; hitbox:SetAttribute("Swimming", true) end
		elseif hitbox.CanQuery then
			hitbox.CanQuery = false; hitbox:SetAttribute("Swimming", false)
		end
	end)

	table.insert(conns, humanoid.Died:Connect(Cleanup))
	table.insert(conns, character.AncestryChanged:Connect(function(_, parent) if not parent then Cleanup() end end))
end

-- ─── INIT ────────────────────────────────────────────────────────────────────
if LocalPlayer.Character then task.spawn(SetupCharacter, LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(SetupCharacter)
