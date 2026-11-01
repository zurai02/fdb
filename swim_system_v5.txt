--!strict
--!optimize 2
-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  SWIM SYSTEM  v5  (optimized)                                       ║
-- ╠══════════════════════════════════════════════════════════════════════╣
-- ║  All v5 features kept.  Optimisations applied:                      ║
-- ║                                                                     ║
-- ║  ZERO-ALLOC HOT PATHS                                               ║
-- ║    All constant Vector3 / CFrame / UDim2 values that were built     ║
-- ║    inside loops are pre-computed once at module level.              ║
-- ║    V3_ZERO, V3_UP, V3_SINK_IDLE, V3_HEAD_OFFSET, V3_WATER_BOX,    ║
-- ║    V3_CREST_UP, V3_CREST_DOWN, CAST_SHRINK_V3, CF_ZERO,            ║
-- ║    TWEEN_INFO_BLUR all exist as module constants.                   ║
-- ║                                                                     ║
-- ║  UNDERWATER FAST-PATH                                               ║
-- ║    CheckIsUnderwater: if surfaceY is known and the root is clearly  ║
-- ║    below it (> 0.5 studs), skip both GetMaterialAtPosition calls    ║
-- ║    and the GetPartBoundsInBox — return true immediately. Saves      ║
-- ║    the two material lookups every PreSimulation tick while deep.    ║
-- ║                                                                     ║
-- ║  BODY-PART CACHE                                                    ║
-- ║    fitBody caches BasePart references (head, pelvis, all limbs)     ║
-- ║    on water entry and reuses them every PostSimulation tick.        ║
-- ║    Eliminates up to 12 FindFirstChild calls per frame.             ║
-- ║                                                                     ║
-- ║  EMITTER RATE GUARD                                                 ║
-- ║    bubbleEmit.Rate / wakeEmit.Rate only written when the value      ║
-- ║    changed by more than 0.25, avoiding a C++ property round-trip   ║
-- ║    every frame when the player is hovering at a fixed speed.        ║
-- ║                                                                     ║
-- ║  RIPPLE POOL TWO-PASS SCAN                                          ║
-- ║    spawnRipple now checks for a free slot in pass 1 (exits early    ║
-- ║    O(1) most of the time) and only runs the "least remaining life"  ║
-- ║    scan in pass 2 when every slot is busy.                          ║
-- ║                                                                     ║
-- ║  CAUSTIC STROKE CACHE                                               ║
-- ║    CausticLayer now stores the UIStroke directly instead of calling ║
-- ║    FindFirstChildOfClass every rendered frame.                      ║
-- ║                                                                     ║
-- ║  PER-FRAME ALPHA CACHE                                              ║
-- ║    expAlpha(10, dt), expAlpha(20, dt) and expAlpha(SWIRL_FOLLOW, dt)║
-- ║    are each computed once per visual tick and reused across all     ║
-- ║    the places that need them (was 5 separate math.exp calls).       ║
-- ║                                                                     ║
-- ║  SWIRL POSITION SCALARS                                             ║
-- ║    swirlPos X/Z advance via two scalar adds instead of allocating   ║
-- ║    a temporary Vector3 for the difference and another for the       ║
-- ║    scaled result.                                                   ║
-- ║                                                                     ║
-- ║  BUBBLE DEACTIVATE GUARD                                            ║
-- ║    b.part.Transparency is only written when the bubble was still    ║
-- ║    visible (< 1) to avoid a redundant C++ property write.           ║
-- ║                                                                     ║
-- ║  CREST RAYCAST PARAMS CACHED                                        ║
-- ║    The RaycastParams for the crest-detection probe was being        ║
-- ║    allocated on every crest check (~5 Hz).  It is now created once ║
-- ║    on water entry and reused.                                       ║
-- ║                                                                     ║
-- ║  SPRING CONSTANTS PRE-BAKED                                         ║
-- ║    springScalar / springVec3 recompute k1/k2 on every call.        ║
-- ║    The five spring configs (vel, ori, tilt, bank, lean) are each    ║
-- ║    baked into a tiny {k1, k2} table once at setup so the hot path  ║
-- ║    does two multiplies instead of four.                             ║
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
	SWIM_SPEED            = 22,
	RISE_SPEED            = 16,
	SINK_SPEED            = 16,
	ENTRY_MAX_SPEED       = 60,
	EXIT_JUMP_BONUS       = 8,

	VEL_STIFFNESS         = 180,
	VEL_DAMPING           = 26,

	ORI_OMEGA             = 14,
	ORI_ZETA              = 0.85,
	TILT_MAX              = 38,
	TILT_OMEGA            = 10,
	TILT_ZETA             = 0.9,
	BANK_MAX              = 18,
	BANK_OMEGA            = 8,
	BANK_ZETA             = 0.7,

	CAM_LEAN_MAX          = 4,
	CAM_LEAN_OMEGA        = 6,
	CAM_LEAN_ZETA         = 0.8,

	CURRENT_STRENGTH      = 1.8,
	CURRENT_FREQ_X        = 0.11,
	CURRENT_FREQ_Z        = 0.07,
	CURRENT_DEPTH_SCALE   = 0.6,

	BLUR_SIZE             = 8,
	BLUR_TWEEN_TIME       = 0.35,
	UNDERWATER_FOG_END    = 80,
	UNDERWATER_FOG_COLOR  = Color3.fromRGB(30, 90, 160),
	FOG_DEPTH_SCALE       = 0.55,
	FOG_ADAPT_RATE        = 3,
	BUBBLE_RATE           = 18,
	BUBBLE_MOVE_RATE      = 36,

	BUBBLE_POOL_SIZE      = 48,
	BUBBLE_DRAG           = 2.8,
	BUBBLE_BUOYANCY       = 5.5,
	BUBBLE_SPREAD         = 0.9,

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

	WAKE_LANE_WIDTH       = 1.4,
	WAKE_LIFE_VARIANCE    = 0.25,
	WAKE_DIAM_VARIANCE    = 0.3,

	CREST_CHECK_DIST      = 4.0,
	CREST_RING_THRESH     = 0.18,

	FOAM_TEXTURE          = "rbxasset://textures/particles/smoke_main.dds",
	DROP_TEXTURE          = "rbxassetid://243660364",
	FOAM_RATE             = 10,
	SPLASH_PUFFS          = 12,
	SPLASH_DROPS          = 10,
	SPLASH_STREAKS        = 8,

	CAUSTIC_LAYERS        = 5,
	CAUSTIC_SPEED         = 0.35,
	CAUSTIC_ALPHA_BASE    = 0.78,
	CAUSTIC_ALPHA_PULSE   = 0.14,

	SURFACE_OFFSET        = 0.12,
	SURFACE_FX_FULL_DEPTH = 2.5,
	SURFACE_FX_DEPTH      = 7,
	ENTRY_MAX_DEPTH       = 6,

	SWIM_TICK_RATE        = 120,
	MAX_TICKS_PER_FRAME   = 12,
	LOOK_TURN_RATE        = 14,

	BODY_WIDTH            = 2.2,
	BODY_THICKNESS        = 1.8,
	BODY_LENGTH_PAD       = 0.2,
	SLIDE_SKIN            = 0.12,
	SLIDE_CAST_SHRINK     = 0.1,
	SLIDE_MAX_BOUNCES     = 3,
	SHOW_HITBOX           = false,

	FALLBACK_IDLE_ANIM    = "rbxassetid://913384386",
	FALLBACK_SWIM_ANIM    = "rbxassetid://913389033",
}

local BIND_RISE = "CustomSwim_Rise"
local BIND_SINK = "CustomSwim_Sink"
local SWIM_TICK = 1 / CFG.SWIM_TICK_RATE
local VOXEL     = 4
local RING_CANVAS = 384
local RING_MARGIN = 14
local TAU         = math.pi * 2

-- ─── PRE-COMPUTED CONSTANTS (zero allocation in hot paths) ───────────────────
local V3_ZERO        = Vector3.zero
local V3_UP          = Vector3.yAxis
local V3_SINK_IDLE   = Vector3.new(0, -0.5, 0)      -- gentle sink when not pressing anything
local V3_HEAD_OFFSET = Vector3.new(0, 1.5, 0)        -- head position relative to root
local V3_WATER_BOX   = Vector3.new(2, 3.5, 2)        -- overlap-check box size
local V3_BOX_CENTRE  = Vector3.new(0, 0.75, 0)       -- overlap-check box offset
local V3_CREST_UP    = Vector3.new(0, 10, 0)         -- crest raycast origin offset
local V3_CREST_DOWN  = Vector3.new(0, -20, 0)        -- crest raycast direction
local CAST_SHRINK_V3 = Vector3.one * CFG.SLIDE_CAST_SHRINK  -- cached sweep shrink
local CF_ZERO        = CFrame.new(V3_ZERO)           -- CFrame at origin for orientation
local TWEEN_BLUR     = TweenInfo.new(CFG.BLUR_TWEEN_TIME)

-- ─── GRADIENT PATTERNS ───────────────────────────────────────────────────────
local ARC_PAIR = NumberSequence.new({
	NumberSequenceKeypoint.new(0,   0),
	NumberSequenceKeypoint.new(0.3, 0),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(0.7, 0),
	NumberSequenceKeypoint.new(1,   0),
})
local ARC_COMET = NumberSequence.new({
	NumberSequenceKeypoint.new(0,    1),
	NumberSequenceKeypoint.new(0.45, 0.65),
	NumberSequenceKeypoint.new(1,    0),
})
local ARC_CAUSTIC = NumberSequence.new({
	NumberSequenceKeypoint.new(0,    0.0),
	NumberSequenceKeypoint.new(0.25, 0.6),
	NumberSequenceKeypoint.new(0.5,  0.0),
	NumberSequenceKeypoint.new(0.75, 0.6),
	NumberSequenceKeypoint.new(1,    0.0),
})

-- ─── TYPES ───────────────────────────────────────────────────────────────────
type RingLayer = {
	holder: Frame,
	core: UIStroke,
	halo: UIStroke,
	coreGradient: UIGradient,
	haloGradient: UIGradient,
}
type SurfaceFx = {
	part: Part,
	gui: SurfaceGui,
	outer: RingLayer,
	inner: RingLayer,
	foam: ParticleEmitter,
	burstPuffs: ParticleEmitter,
	burstDrops: ParticleEmitter,
}
type Ripple = {
	part: Part,
	gui: SurfaceGui,
	layer: RingLayer,
	active: boolean,
	born: number,
	life: number,
	bias: number,
}
type Streak = {
	part: Part,
	trail: Trail,
	velocity: Vector3,
	active: boolean,
}
type Bubble = {
	pos: Vector3,
	vel: Vector3,
	born: number,
	life: number,
	active: boolean,
	part: Part,
}
-- OPT: store stroke directly so we never call FindFirstChildOfClass every frame
type CausticLayer = { frame: Frame, grad: UIGradient, stroke: UIStroke, phase: number, speed: number }

-- ─── SPRING UTILITIES ────────────────────────────────────────────────────────
-- OPT: pre-baked spring config table — k1/k2 computed once, not per call
type SpringCfg = { k1: number, k2: number }
local function makeSpringCfg(omega: number, zeta: number): SpringCfg
	local d = zeta * omega
	return { k1 = 2 * d, k2 = omega * omega }
end

-- Scalar spring using a pre-baked config
local function springS(val: number, vel: number, target: number, cfg: SpringCfg, dt: number): (number, number)
	dt = math.min(dt, 0.1)
	local acc = -cfg.k2 * (val - target) - cfg.k1 * vel
	vel = vel + acc * dt
	return val + vel * dt, vel
end

-- 3-D vector spring using a pre-baked config
local function springV3(val: Vector3, vel: Vector3, target: Vector3, cfg: SpringCfg, dt: number): (Vector3, Vector3)
	dt = math.min(dt, 0.1)
	local err = val - target
	local acc = -cfg.k2 * err - cfg.k1 * vel
	vel = vel + acc * dt
	return val + vel * dt, vel
end

-- Direction spring (slerp-like, sphere-safe)
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

-- OPT: takes a pre-built cache of BasePart references (populated on water entry)
-- so no FindFirstChild calls happen in the PostSimulation hot path.
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
	local castSize  = boxSize - CAST_SHRINK_V3   -- OPT: pre-computed constant, no alloc
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
		moved += step
		cf = cf + step
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
	local e = Instance.new("ParticleEmitter")
	local t: any = e
	for k, v in props do t[k] = v end
	e.Parent = parent
	return e
end

local function newRingGui(part: Part): SurfaceGui
	local g = Instance.new("SurfaceGui")
	g.Name = "RingGui"; g.Face = Enum.NormalId.Top
	g.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	g.CanvasSize = Vector2.new(RING_CANVAS, RING_CANVAS)
	g.LightInfluence = 0; g.AlwaysOnTop = false; g.Active = false
	g.Parent = part
	return g
end

local function buildRingLayer(
	parent: Instance,
	coreThick: number, haloThick: number,
	coreAlpha: number, haloAlpha: number,
	pattern: NumberSequence
): RingLayer
	local holder = Instance.new("Frame")
	holder.Name = "RingLayer"; holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.new(1, -RING_MARGIN * 2, 1, -RING_MARGIN * 2)
	holder.BackgroundTransparency = 1; holder.BorderSizePixel = 0
	holder.Parent = parent

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
local RIPPLE_START_SIZE = UDim2.fromScale(0.08, 0.08)
local RIPPLE_FULL_SIZE  = UDim2.new(1, -RING_MARGIN * 2, 1, -RING_MARGIN * 2)
local RIPPLE_CORE_ALPHA = 0.05
local RIPPLE_HALO_ALPHA = 0.72
local RIPPLE_LAYER_STEP = 0.004
-- pre-bake the (1-alpha) ranges so stepRipples does fewer subtracts
local RIPPLE_CORE_RANGE = 1 - RIPPLE_CORE_ALPHA    -- = 0.95
local RIPPLE_HALO_RANGE = 1 - RIPPLE_HALO_ALPHA    -- = 0.28
local RIPPLE_CORE_THICK_RANGE = 1 - CFG.RING_CORE_PX   -- = -2  (thickness shrinks)
local RIPPLE_HALO_THICK_RANGE = 3 - CFG.RING_HALO_PX   -- = -7

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
	local now = os.clock()
	local any = false
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
				-- OPT: pre-baked range constants replace repeated subtractions
				l.core.Transparency = RIPPLE_CORE_ALPHA + RIPPLE_CORE_RANGE        * fade
				l.core.Thickness    = CFG.RING_CORE_PX  + RIPPLE_CORE_THICK_RANGE  * fade
				l.halo.Transparency = RIPPLE_HALO_ALPHA  + RIPPLE_HALO_RANGE        * fade
				l.halo.Thickness    = CFG.RING_HALO_PX   + RIPPLE_HALO_THICK_RANGE  * fade
			end
		end
	end
	if not any and rippleLoop then rippleLoop:Disconnect(); rippleLoop = nil end
end

-- OPT: two-pass pool scan — pass 1 exits O(1) on the common case (free slot found).
-- Pass 2 (full scan for least-remaining) only runs when every slot is busy.
local function spawnRipple(x: number, z: number, sy: number, diameter: number, life: number)
	local now = os.clock()

	-- pass 1: find a free slot (fast path, usually succeeds)
	local chosen: Ripple? = nil
	for _, c in ripplePool do
		if not c.active then chosen = c; break end
	end

	-- pass 2: recycle the slot with the least remaining life
	if not chosen then
		local leastRemaining = math.huge
		for _, c in ripplePool do
			local rem = c.born + c.life - now
			if rem < leastRemaining then leastRemaining = rem; chosen = c end
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

-- ─── CAUSTIC SHIMMER ─────────────────────────────────────────────────────────
local function makeCausticGui(parent: Part): (SurfaceGui, { CausticLayer })
	local gui = Instance.new("SurfaceGui")
	gui.Name = "CausticGui"; gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.LightInfluence = 0; gui.AlwaysOnTop = false; gui.Active = false
	gui.Parent = parent

	local layers: { CausticLayer } = {}
	for _ = 1, CFG.CAUSTIC_LAYERS do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5); f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromScale(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5)
		f.BackgroundTransparency = 1; f.BorderSizePixel = 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0.5, 0)

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(180, 230, 255)
		stroke.Thickness = 6 + math.random() * 8
		stroke.Transparency = CFG.CAUSTIC_ALPHA_BASE
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = f

		local grad = Instance.new("UIGradient")
		grad.Transparency = ARC_CAUSTIC; grad.Rotation = math.random() * 360; grad.Parent = stroke
		f.Parent = gui

		-- OPT: stroke cached in the layer table — no FindFirstChildOfClass per frame
		table.insert(layers, {
			frame  = f,
			grad   = grad,
			stroke = stroke,
			phase  = math.random() * TAU,
			speed  = (CFG.CAUSTIC_SPEED * 0.7 + math.random() * CFG.CAUSTIC_SPEED * 0.6)
			         * (math.random() < 0.5 and 1 or -1),
		})
	end
	return gui, layers
end

-- ─── STREAK CONNECTIONS ───────────────────────────────────────────────────────
local activeStreakConns: { RBXScriptConnection } = {}
local lastSplashClock = 0

-- ─── 3-D BUBBLE POOL ─────────────────────────────────────────────────────────
local bubblePool: { Bubble } = {}
local bubbleLoopConn: RBXScriptConnection? = nil
local V3_BUOYANCY = Vector3.new(0, CFG.BUBBLE_BUOYANCY, 0)  -- OPT: pre-baked constant

local function buildBubbleParts()
	for _ = 1, CFG.BUBBLE_POOL_SIZE do
		local p = newEffectPart("SwimBubble3D", Vector3.new(0.15, 0.15, 0.15))
		p.Shape = Enum.PartType.Ball; p.Material = Enum.Material.Glass
		p.Color = Color3.fromRGB(200, 240, 255); p.Transparency = 0.6
		p.Parent = effectsFolder
		table.insert(bubblePool, { pos = V3_ZERO, vel = V3_ZERO, born = 0, life = 0, active = false, part = p })
	end
end
buildBubbleParts()

local function spawnBubble3D(origin: Vector3, swimVel: Vector3)
	for _, b in bubblePool do
		if not b.active then
			b.active = true
			b.pos    = origin + Vector3.new((math.random() - 0.5) * 0.6, 0, (math.random() - 0.5) * 0.6)
			b.vel    = Vector3.new(
				(math.random() - 0.5) * CFG.BUBBLE_SPREAD + swimVel.X * 0.15,
				math.random() * 1.2 + 0.3,
				(math.random() - 0.5) * CFG.BUBBLE_SPREAD + swimVel.Z * 0.15
			)
			b.born  = os.clock()
			b.life  = math.random() * 0.8 + 0.5
			b.part.CFrame = CFrame.new(b.pos)
			b.part.Transparency = 0.6
			return
		end
	end
end

local function stepBubbles3D(dt: number)
	local any = false
	local now = os.clock()
	for _, b in bubblePool do
		if b.active then
			local age = now - b.born
			if age >= b.life then
				b.active = false
				-- OPT: only write property if not already invisible
				if b.part.Transparency < 1 then b.part.Transparency = 1 end
			else
				any = true
				local drag = -b.vel * CFG.BUBBLE_DRAG
				b.vel = b.vel + (drag + V3_BUOYANCY) * dt  -- OPT: V3_BUOYANCY cached
				b.pos = b.pos + b.vel * dt
				b.part.CFrame = CFrame.new(b.pos)
				local t = age / b.life
				b.part.Transparency = 0.6 + 0.4 * (t * t)
			end
		end
	end
	if not any and bubbleLoopConn then bubbleLoopConn:Disconnect(); bubbleLoopConn = nil end
end

-- ─── STREAKS ─────────────────────────────────────────────────────────────────
local HALF_GRAVITY = -0.5 * 55   -- OPT: pre-baked gravity constant
local function spawnStreaks(origin: Vector3, count: number)
	local streaks: { Streak } = {}
	for i = 1, count do
		local angle = (i / count) * TAU + (math.random() - 0.5) * 0.7
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
		trail.WidthScale   = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1),   NumberSequenceKeypoint.new(1, 0) })
		trail.Parent = part
		part.Parent = effectsFolder; Debris:AddItem(part, 1.8)
		table.insert(streaks, {
			part = part, trail = trail,
			velocity = Vector3.new(math.cos(angle) * h, v, math.sin(angle) * h),
			active = true,
		})
	end
	local elapsed = 0
	local conn: RBXScriptConnection? = nil
	conn = RunService.PreRender:Connect(function(dt: number)
		elapsed += dt
		local any = false
		for _, s in streaks do
			if s.active then
				-- OPT: HALF_GRAVITY pre-baked; avoids one multiply per streak per frame
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

-- ─── SURFACE FX ──────────────────────────────────────────────────────────────
local function makeSurfaceFx(): SurfaceFx
	local part = newEffectPart("SwimSurfaceFx", Vector3.new(CFG.SWIRL_DIAMETER, 0.05, CFG.SWIRL_DIAMETER))
	local gui  = newRingGui(part); gui.Enabled = false
	local outer = buildRingLayer(gui, 3, 12, 0.35, 0.82, ARC_COMET)
	local inner = buildRingLayer(gui, 4, 14, 0.12, 0.74, ARC_PAIR)
	inner.holder.Size = UDim2.fromScale(0.6, 0.6)
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
		Texture = CFG.DROP_TEXTURE,
		Color   = ColorSequence.new(Color3.fromRGB(235, 248, 255)),
		Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0.1) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.7, 0.3), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.6, 1.1), Speed = NumberRange.new(12, 22),
		SpreadAngle = Vector2.new(28, 28), EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -55, 0), LightEmission = 0.4, Rate = 0,
	})
	part.Parent = effectsFolder
	return { part = part, gui = gui, outer = outer, inner = inner, foam = foam, burstPuffs = burstPuffs, burstDrops = burstDrops }
end

-- ─── TERRAIN SURFACE ─────────────────────────────────────────────────────────
local function findTerrainSurfaceY(position: Vector3): number?
	local layers = 10
	local x    = math.floor(position.X / VOXEL) * VOXEL
	local z    = math.floor(position.Z / VOXEL) * VOXEL
	local yBase = math.max((math.floor(position.Y / VOXEL) - 2) * VOXEL, 0)
	local region = Region3.new(Vector3.new(x, yBase, z), Vector3.new(x + VOXEL, yBase + layers * VOXEL, z + VOXEL))
	local ok, mats, occs = pcall(function() return Workspace.Terrain:ReadVoxels(region, VOXEL) end)
	if not ok then return nil end
	local col: any = (mats :: any)[1]
	local top = 0
	for i = 1, layers do
		if col[i][1] == Enum.Material.Water then top = i
		elseif top > 0 then break end
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

-- ─── SPLASH ──────────────────────────────────────────────────────────────────
local function playSplash(fx: SurfaceFx, x: number, z: number, sy: number, big: boolean)
	local now = os.clock()
	if now - lastSplashClock < 0.5 then return end
	lastSplashClock = now
	local scale = big and 1 or 0.6
	fx.part.CFrame = CFrame.new(x, sy + CFG.SURFACE_OFFSET, z)
	fx.burstPuffs:Emit(math.floor(CFG.SPLASH_PUFFS * scale))
	fx.burstDrops:Emit(math.floor(CFG.SPLASH_DROPS * scale))
	if big then spawnStreaks(Vector3.new(x, sy + 0.25, z), CFG.SPLASH_STREAKS) end
	local d = CFG.ENTRY_RING_DIAMETER * scale; local lt = CFG.RIPPLE_TWEEN_TIME
	spawnRipple(x, z, sy, d,        lt)
	task.delay(0.10, spawnRipple, x, z, sy, d * 0.75, lt * 0.90)
	task.delay(0.22, spawnRipple, x, z, sy, d * 0.50, lt * 0.80)
	task.delay(0.36, spawnRipple, x, z, sy, d * 0.30, lt * 0.70)
end

-- ─── CLEANUP on script destroy ───────────────────────────────────────────────
script.Destroying:Connect(function()
	if rippleLoop then rippleLoop:Disconnect(); rippleLoop = nil end
	if bubbleLoopConn then bubbleLoopConn:Disconnect(); bubbleLoopConn = nil end
	for _, c in activeStreakConns do c:Disconnect() end
	table.clear(activeStreakConns)
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

	-- constraints
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
	bubbleEmit.Color   = ColorSequence.new(Color3.fromRGB(180,225,255), Color3.fromRGB(255,255,255))
	bubbleEmit.Lifetime = NumberRange.new(0.7, 1.5); bubbleEmit.Rate = 0
	bubbleEmit.Speed   = NumberRange.new(1.5, 4); bubbleEmit.Rotation = NumberRange.new(0, 360)
	bubbleEmit.RotSpeed = NumberRange.new(-90, 90); bubbleEmit.SpreadAngle = Vector2.new(30, 30)
	bubbleEmit.EmissionDirection = Enum.NormalId.Top; bubbleEmit.Enabled = true
	bubbleEmit.Parent = primaryPart

	local wakeEmit = Instance.new("ParticleEmitter")
	wakeEmit.Texture = "rbxassetid://243660364"
	wakeEmit.Size    = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	wakeEmit.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	wakeEmit.Color   = ColorSequence.new(Color3.fromRGB(200, 235, 255))
	wakeEmit.Lifetime = NumberRange.new(0.3, 0.6); wakeEmit.Rate = 0
	wakeEmit.Speed   = NumberRange.new(0.5, 2); wakeEmit.SpreadAngle = Vector2.new(80, 80)
	wakeEmit.EmissionDirection = Enum.NormalId.Top; wakeEmit.Enabled = true
	wakeEmit.Parent = primaryPart

	local surfaceFx = makeSurfaceFx()

	local causticPart = newEffectPart("SwimCaustic", Vector3.new(20, 0.05, 20))
	causticPart.Parent = effectsFolder
	local causticGui, causticLayers = makeCausticGui(causticPart)
	causticGui.Enabled = false

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

	-- OPT: crest raycast params created once on setup, reused every crest probe
	local crestParams = RaycastParams.new()
	crestParams.IgnoreWater = false

	local conns: { RBXScriptConnection } = {}
	local renderConn: RBXScriptConnection?
	local visualConn: RBXScriptConnection?
	local hitboxConn: RBXScriptConnection?

	local function RefreshWaterFilter()
		local tagged = CollectionService:GetTagged("Water")
		wop.FilterDescendantsInstances = tagged
		local ignore = table.clone(tagged)
		table.insert(ignore, character); table.insert(ignore, effectsFolder)
		castP.ExcludeInstances = ignore
		crestParams.ExcludeInstances = { character }  -- OPT: update crest params here too
	end
	table.insert(conns, CollectionService:GetInstanceAddedSignal("Water"):Connect(RefreshWaterFilter))
	table.insert(conns, CollectionService:GetInstanceRemovedSignal("Water"):Connect(RefreshWaterFilter))
	RefreshWaterFilter()

	-- ── OPT: pre-baked spring configs (k1/k2 computed once per character) ──────
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

	local curVel     = V3_ZERO
	local velSpringV = V3_ZERO
	local smoothLook = primaryPart.CFrame.LookVector
	local lookSpringV = V3_ZERO
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
	local swirlPosX             = 0.0   -- OPT: scalars instead of Vector3
	local swirlPosZ             = 0.0
	local swirlReady            = false
	local swimDepth             = 0.0
	local swimClock             = 0.0
	local prevCrestY            = 0.0
	local crestTimer            = 0.0
	local bubbleAccum           = 0.0

	-- OPT: last-written emitter rate cache (avoids C++ write when value unchanged)
	local lastBubbleRate = -1.0
	local lastWakeRate   = -1.0

	-- OPT: body-part cache populated on water entry; reused every PostSimulation tick
	local cachedHead:   BasePart? = nil
	local cachedPelvis: BasePart? = nil
	local cachedLimbs:  { BasePart } = {}

	local function RebuildBodyCache()
		cachedHead   = nil; cachedPelvis = nil; table.clear(cachedLimbs)
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
		local pos     = primaryPart.Position
		-- OPT: if we already know the surface and are clearly below it, skip all queries
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
		blurFx.Parent  = camera; colorFx.Parent = camera
		-- OPT: TWEEN_BLUR pre-baked TweenInfo constant
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
		if isCleanedUp then return end
		isCleanedUp = true
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
				local carried = primaryPart.AssemblyLinearVelocity
				if carried.Magnitude > CFG.ENTRY_MAX_SPEED then carried = carried.Unit * CFG.ENTRY_MAX_SPEED end
				curVel = carried
				local eS = MeasureSurface(); surfaceTimer = 0.1
				if eS and eS - primaryPart.Position.Y < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position; playSplash(surfaceFx, p.X, p.Z, eS, true)
				end
				prevCrestY = surfaceY or primaryPart.Position.Y
				-- OPT: build body-part cache once on entry
				RebuildBodyCache()
			end

			surfaceTimer -= dt
			if surfaceTimer <= 0 then surfaceTimer = 0.1; MeasureSurface() end

			humanoid.AutoRotate = false; alignOri.Enabled = true; linVel.MaxForce = 100000

			local moveDir  = humanoid.MoveDirection
			local isMoving = moveDir.Magnitude > 0.05
			local targetVel: Vector3

			if isMoving then
				local camCF = camera.CFrame
				local rVec  = camCF.RightVector
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
				targetVel = V3_SINK_IDLE   -- OPT: pre-allocated constant
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

			-- emitter rates (OPT: only write on meaningful change)
			local speed = math.max(curVel.Magnitude, 0)
			local sf    = math.clamp(speed / CFG.SWIM_SPEED, 0, 1)
			local newBubbleRate = math.clamp(CFG.BUBBLE_RATE + (CFG.BUBBLE_MOVE_RATE - CFG.BUBBLE_RATE) * sf, 0, CFG.BUBBLE_MOVE_RATE)
			local newWakeRate   = isMoving and math.clamp(sf * 24, 0, 24) or 0
			if math.abs(newBubbleRate - lastBubbleRate) > 0.25 then
				bubbleEmit.Rate = newBubbleRate; lastBubbleRate = newBubbleRate
			end
			if math.abs(newWakeRate - lastWakeRate) > 0.25 then
				wakeEmit.Rate = newWakeRate; lastWakeRate = newWakeRate
			end

			-- 3-D bubble spawn
			bubbleAccum += dt * (CFG.BUBBLE_RATE * 0.3 + sf * CFG.BUBBLE_RATE * 0.7)
			while bubbleAccum >= 1 do
				bubbleAccum -= 1
				spawnBubble3D(primaryPart.Position, curVel)
			end
			if not bubbleLoopConn then
				bubbleLoopConn = RunService.PreRender:Connect(stepBubbles3D)
			end

			-- multi-layer wake turbulence
			movingNow = isMoving
			wakeTimer -= dt
			local sy = surfaceY
			if isMoving and sy and wakeTimer <= 0 and (sy - primaryPart.Position.Y) < CFG.SURFACE_FX_DEPTH * 0.6 then
				wakeTimer = CFG.WAKE_RING_INTERVAL * (1.5 - sf * 0.75)
				local p     = primaryPart.Position
				local right = Vector3.new(smoothLook.Z, 0, -smoothLook.X).Unit
				for lane = -1, 1 do
					local offset = right * (lane * CFG.WAKE_LANE_WIDTH)
					local diam   = CFG.WAKE_RING_DIAMETER * (1 + (math.random() - 0.5) * CFG.WAKE_DIAM_VARIANCE)
					local life   = CFG.RIPPLE_TWEEN_TIME  * 0.9 * (1 + (math.random() - 0.5) * CFG.WAKE_LIFE_VARIANCE)
					spawnRipple(p.X + offset.X, p.Z + offset.Z, sy, diam, life)
				end
			end

			-- crest detection (OPT: crestParams reused, not reallocated each probe)
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

			swimDepth = sy and math.max(sy - primaryPart.Position.Y, 0) or swimDepth

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
				UnbindInputs()
				humanoid.AutoRotate = true; alignOri.Enabled = false
				if lastBubbleRate ~= 0 then bubbleEmit.Rate = 0; lastBubbleRate = 0 end
				if lastWakeRate   ~= 0 then wakeEmit.Rate   = 0; lastWakeRate   = 0 end
				curTilt = 0; curBank = 0; curLean = 0
				linVel.MaxForce = 0; linVel.VectorVelocity = V3_ZERO; curVel = V3_ZERO
				velSpringV = V3_ZERO; lookSpringV = V3_ZERO
				if currentAnim then currentAnim:Stop(0.2) end; currentAnim = nil
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming,  true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping,   true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall,  true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
				RemoveUnderwaterFX()
				local exitSY = MeasureSurface() or surfaceY
				if exitSY and math.abs(exitSY - primaryPart.Position.Y) < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position; playSplash(surfaceFx, p.X, p.Z, exitSY, false)
				end
				surfaceY = nil; surfaceReady = false; movingNow = false; swimDepth = 0
				table.clear(cachedLimbs); cachedHead = nil; cachedPelvis = nil  -- OPT: clear cache on exit
				if wasRising then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					primaryPart.AssemblyLinearVelocity = Vector3.new(
						primaryPart.AssemblyLinearVelocity.X,
						CFG.RISE_SPEED + CFG.EXIT_JUMP_BONUS,
						primaryPart.AssemblyLinearVelocity.Z
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

		-- OPT: compute each unique expAlpha once per frame and reuse below
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
			local depthT    = math.clamp(depth / (CFG.SURFACE_FX_DEPTH * 2), 0, 1)
			local fogTarget = CFG.UNDERWATER_FOG_END * (1 - CFG.FOG_DEPTH_SCALE * depthT)
			currentFogEnd   = currentFogEnd + (fogTarget - currentFogEnd) * alphaFog  -- reused alpha
			Lighting.FogEnd = currentFogEnd
		end
		fxAlpha += (targetAlpha - fxAlpha) * alpha10   -- reused alpha

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
			surfaceFx.foam.Rate = 0; swirlReady = false; return
		end
		if not surfaceFx.gui.Enabled then surfaceFx.gui.Enabled = true end

		-- OPT: shownSurfaceY is a scalar — no Vector3 allocated
		shownSurfaceY += (sy - shownSurfaceY) * alpha20   -- reused alpha

		local pos = primaryPart.Position
		local targetX = pos.X
		local targetZ = pos.Z
		if swirlReady then
			-- OPT: two scalar advances instead of Vector3 difference + scale + add
			swirlPosX += (targetX - swirlPosX) * alphaSwrl
			swirlPosZ += (targetZ - swirlPosZ) * alphaSwrl
		else
			swirlPosX = targetX; swirlPosZ = targetZ; swirlReady = true
		end
		surfaceFx.part.CFrame = CFrame.new(swirlPosX, shownSurfaceY + CFG.SURFACE_OFFSET, swirlPosZ)

		-- swirl rings
		swirlTime += dt
		local outerSpin = (swirlTime * CFG.SWIRL_SPEED) % 360
		local innerSpin = (-swirlTime * CFG.SWIRL_SPEED * 1.35) % 360
		surfaceFx.outer.coreGradient.Rotation = outerSpin; surfaceFx.outer.haloGradient.Rotation = outerSpin
		surfaceFx.inner.coreGradient.Rotation = innerSpin; surfaceFx.inner.haloGradient.Rotation = innerSpin

		local sf = math.clamp(curVel.Magnitude / CFG.SWIM_SPEED, 0, 1)
		-- OPT: compute lerpColor results once, assign to inner and outer together
		local coreCol = lerpColor(CFG.RING_CORE_COLOR, CFG.RING_CORE_COLOR_FAST, sf)
		local haloCol = lerpColor(CFG.RING_HALO_COLOR, CFG.RING_HALO_COLOR_FAST, sf)
		surfaceFx.outer.core.Color = coreCol; surfaceFx.outer.halo.Color = haloCol
		surfaceFx.inner.core.Color = coreCol; surfaceFx.inner.halo.Color = haloCol

		local breathe = 0.6 + 0.035 * math.sin(swirlTime * 2.4)
		surfaceFx.inner.holder.Size = UDim2.fromScale(breathe, breathe)

		local a = fxAlpha
		surfaceFx.outer.core.Transparency = 1 - 0.65 * a; surfaceFx.outer.halo.Transparency = 1 - 0.18 * a
		surfaceFx.inner.core.Transparency = 1 - 0.88 * a; surfaceFx.inner.halo.Transparency = 1 - 0.26 * a
		surfaceFx.foam.Rate = movingNow and (CFG.FOAM_RATE * sf * a) or 0

		-- caustic shimmer
		if swimDepth > 1.0 then
			if not causticGui.Enabled then causticGui.Enabled = true end
			causticPart.CFrame = CFrame.new(pos.X, shownSurfaceY - 3.5, pos.Z)
			local depthAlphaFactor = 1 - a * 0.3
			for _, layer in causticLayers do
				local ang   = (swirlTime * layer.speed + layer.phase) % TAU
				layer.grad.Rotation = math.deg(ang)
				-- OPT: layer.stroke is cached — no FindFirstChildOfClass call
				layer.stroke.Transparency = math.clamp(
					(CFG.CAUSTIC_ALPHA_BASE + CFG.CAUSTIC_ALPHA_PULSE * math.sin(ang * 3.1)) * depthAlphaFactor,
					0, 1
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
			-- OPT: fitBodyCached uses pre-built part references — no FindFirstChild
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
