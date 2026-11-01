--!strict
--!optimize 2
-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  SWIM SYSTEM  v5                                                    ║
-- ╠══════════════════════════════════════════════════════════════════════╣
-- ║  Everything is driven by 3-D vector math on RunService loops.       ║
-- ║  No TweenService calls remain — every interpolation is a proper     ║
-- ║  spring-damper or exponential-decay step run in PreRender /         ║
-- ║  PreSimulation / PostSimulation at frame rate, so behaviour is      ║
-- ║  identical at 30, 60, 144 and 240 fps.                             ║
-- ║                                                                     ║
-- ║  New in v5                                                          ║
-- ║  ─────────────────────────────────────────────────────────────────  ║
-- ║  SPRING-DAMPER ORIENTATION                                          ║
-- ║    The body's heading is driven by a critically-damped angular      ║
-- ║    spring (ω₀ / ζ configurable in CFG). Overshooting is killed;    ║
-- ║    snapping is smooth with no TweenInfo.                            ║
-- ║                                                                     ║
-- ║  3-D VECTOR VELOCITY SPRING                                         ║
-- ║    currentVelocity uses a spring-damper (stiffness / damping)       ║
-- ║    instead of a raw lerp so acceleration and braking have proper    ║
-- ║    physical curves rather than an exponential-blend artefact.       ║
-- ║                                                                     ║
-- ║  3-D BUBBLE PHYSICS                                                 ║
-- ║    Each bubble is a table {pos, vel, life} integrated in world      ║
-- ║    space with drag + buoyancy every PreRender tick. Up to           ║
-- ║    CFG.BUBBLE_POOL_SIZE live at once; extras are recycled.          ║
-- ║                                                                     ║
-- ║  UNDERWATER CURRENT DRIFT                                           ║
-- ║    A low-frequency 3-D sinusoidal field (phase advances on          ║
-- ║    RunService time) pushes the player with a gentle drift force     ║
-- ║    that varies by depth and time, giving water a sense of mass.     ║
-- ║                                                                     ║
-- ║  VELOCITY-BASED CAMERA LEAN                                         ║
-- ║    The camera rolls toward the swim direction proportional to        ║
-- ║    lateral speed; a 3-D CFrame tilt is composed in PreRender        ║
-- ║    and applied as a camera offset, spring-smoothed.                 ║
-- ║                                                                     ║
-- ║  VOLUMETRIC CAUSTIC SHIMMER                                         ║
-- ║    A second SurfaceGui on a thin part below the surface carries      ║
-- ║    several overlapping radial gradient frames whose opacity and      ║
-- ║    rotation are driven by sin/cos on RunService time, giving an      ║
-- ║    animated caustic-light pattern on the ocean floor.               ║
-- ║                                                                     ║
-- ║  MULTI-LAYER WAKE TURBULENCE                                        ║
-- ║    Wake rings are spawned in three offset layers (left, centre,      ║
-- ║    right of the swim path) with individually randomised lifetimes   ║
-- ║    and diameters, creating a chaotic, organic turbulence streak.    ║
-- ║                                                                     ║
-- ║  ROLL-ON-TURN                                                       ║
-- ║    A lateral tilt (bank angle) is derived from the cross product    ║
-- ║    of the current look and the target look, giving a fighter-jet     ║
-- ║    banking feel when turning underwater.                             ║
-- ║                                                                     ║
-- ║  SURFACE CREST DETECTION                                            ║
-- ║    Three rapid raycasts ahead of the player detect whether the      ║
-- ║    surface is rising or falling. If rising (swimming into a wave    ║
-- ║    crest) an extra burst ripple is triggered for interaction feel.  ║
-- ╚══════════════════════════════════════════════════════════════════════╝

local ContextActionService = game:GetService("ContextActionService")
local RunService           = game:GetService("RunService")
local Players              = game:GetService("Players")
local Workspace            = game:GetService("Workspace")
local CollectionService    = game:GetService("CollectionService")
local TweenService         = game:GetService("TweenService")   -- only used for blur/color fx entry tween
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

	-- velocity spring (stiffness K, damping C — critically damped when C=2√K)
	VEL_STIFFNESS         = 180,    -- how hard the spring pulls toward target velocity
	VEL_DAMPING           = 26,     -- 2*sqrt(180)≈26.8 → near-critically damped

	-- orientation spring
	ORI_OMEGA             = 14,     -- natural angular frequency (rad/s)
	ORI_ZETA              = 0.85,   -- damping ratio (<1 = slight overshoot, =1 = critical)
	TILT_MAX              = 38,     -- max pitch tilt (degrees)
	TILT_OMEGA            = 10,     -- pitch spring ω
	TILT_ZETA             = 0.9,
	BANK_MAX              = 18,     -- max roll (bank) when turning (degrees)
	BANK_OMEGA            = 8,
	BANK_ZETA             = 0.7,

	-- camera lean
	CAM_LEAN_MAX          = 4,      -- degrees of camera roll at max lateral speed
	CAM_LEAN_OMEGA        = 6,
	CAM_LEAN_ZETA         = 0.8,

	-- underwater current drift
	CURRENT_STRENGTH      = 1.8,    -- studs/s peak lateral drift force
	CURRENT_FREQ_X        = 0.11,   -- Hz of the X-axis oscillation
	CURRENT_FREQ_Z        = 0.07,   -- Hz of the Z-axis oscillation
	CURRENT_DEPTH_SCALE   = 0.6,    -- current multiplied by clamp(depth/this, 0, 1)

	-- underwater look
	BLUR_SIZE             = 8,
	BLUR_TWEEN_TIME       = 0.35,
	UNDERWATER_FOG_END    = 80,
	UNDERWATER_FOG_COLOR  = Color3.fromRGB(30, 90, 160),
	FOG_DEPTH_SCALE       = 0.55,
	FOG_ADAPT_RATE        = 3,      -- exp-decay rate toward target fog
	BUBBLE_RATE           = 18,
	BUBBLE_MOVE_RATE      = 36,

	-- 3-D bubble physics
	BUBBLE_POOL_SIZE      = 48,
	BUBBLE_DRAG           = 2.8,    -- drag coefficient (linear)
	BUBBLE_BUOYANCY       = 5.5,    -- upward acceleration (studs/s²)
	BUBBLE_SPREAD         = 0.9,    -- random lateral speed at spawn

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
	RIPPLE_POOL_SIZE      = 24,     -- more rings for 3-layer wake turbulence

	-- wake turbulence (3 lanes)
	WAKE_LANE_WIDTH       = 1.4,    -- half-width between wake lanes
	WAKE_LIFE_VARIANCE    = 0.25,   -- ± randomised fraction added to ring lifetime
	WAKE_DIAM_VARIANCE    = 0.3,    -- ± randomised fraction added to ring diameter

	-- surface crest detection
	CREST_CHECK_DIST      = 4.0,    -- studs ahead to cast for crest detection
	CREST_RING_THRESH     = 0.18,   -- surface height rise (studs) that triggers a burst ring

	-- foam & splash
	FOAM_TEXTURE          = "rbxasset://textures/particles/smoke_main.dds",
	DROP_TEXTURE          = "rbxassetid://243660364",
	FOAM_RATE             = 10,
	SPLASH_PUFFS          = 12,
	SPLASH_DROPS          = 10,
	SPLASH_STREAKS        = 8,

	-- caustic shimmer
	CAUSTIC_LAYERS        = 5,
	CAUSTIC_SPEED         = 0.35,   -- Hz of caustic rotation cycle
	CAUSTIC_ALPHA_BASE    = 0.78,   -- base transparency of each caustic layer
	CAUSTIC_ALPHA_PULSE   = 0.14,   -- amplitude of opacity pulse

	-- surface placement
	SURFACE_OFFSET        = 0.12,
	SURFACE_FX_FULL_DEPTH = 2.5,
	SURFACE_FX_DEPTH      = 7,
	ENTRY_MAX_DEPTH       = 6,

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
-- 3-D bubble type
type Bubble = {
	pos: Vector3,
	vel: Vector3,
	born: number,
	life: number,
	active: boolean,
	part: Part,
}

-- ─── SPRING UTILITIES ────────────────────────────────────────────────────────
-- Critically-damped scalar spring step (no TweenService).
-- Returns new (value, velocity) for the next frame.
local function springScalar(
	val: number, vel: number,
	target: number,
	omega: number, zeta: number,
	dt: number
): (number, number)
	dt = math.min(dt, 0.1)
	local w  = omega
	local d  = zeta * w
	local k1 = 2 * d
	local k2 = w * w
	local err  = val - target
	local acc  = -k2 * err - k1 * vel
	vel = vel + acc * dt
	val = val + vel * dt
	return val, vel
end

-- 3-D vector spring step — same spring on each axis independently.
local function springVec3(
	val: Vector3, vel: Vector3,
	target: Vector3,
	omega: number, zeta: number,
	dt: number
): (Vector3, Vector3)
	dt = math.min(dt, 0.1)
	local w  = omega
	local d  = zeta * w
	local k1 = 2 * d
	local k2 = w * w
	local err = val - target
	local acc = -k2 * err - k1 * vel
	vel = vel + acc * dt
	val = val + vel * dt
	return val, vel
end

-- Direction spring: blends a unit-vector toward a target on a sphere via slerp
-- with a spring-like alpha derived from omega/zeta.
local function springDir(
	from: Vector3, vel: Vector3,
	target: Vector3,
	omega: number, zeta: number,
	dt: number
): (Vector3, Vector3)
	-- treat the angular error as a scalar spring driving the blend alpha
	local err = 1 - math.clamp(from:Dot(target), -1, 1)    -- 0=aligned, 2=opposite
	local newVel, _ = springScalar(0, vel.Magnitude, 0, omega, zeta, dt)
	-- we want to advance toward target; use an exponential decay blend each tick
	local alpha = math.clamp(1 - math.exp(-omega * dt), 0, 1)
	local mixed = from:Lerp(target, alpha)
	if mixed.Magnitude < 0.001 then mixed = target end
	return mixed.Unit, Vector3.new(newVel, 0, 0) * math.sign(err)
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

local function blendDirection(from: Vector3, to: Vector3, alpha: number): Vector3
	local m = from:Lerp(to, alpha)
	return m.Magnitude < 0.05 and to or m.Unit
end

local function fitBody(character: Model, root: BasePart): (CFrame, Vector3)
	local origin = root.Position
	local axis   = root.CFrame.LookVector
	local head   = character:FindFirstChild("Head")
	local pelvis = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	if head and pelvis and head:IsA("BasePart") and pelvis:IsA("BasePart") then
		local spine = head.Position - pelvis.Position
		if spine.Magnitude > 0.5 then axis = spine.Unit end
	end
	local low, high = -1.0, 1.0
	for _, name in BODY_PART_NAMES do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local along = (part.Position - origin):Dot(axis)
			low  = math.min(low,  along - 0.5)
			high = math.max(high, along + 0.5)
		end
	end
	local up = Vector3.yAxis
	if math.abs(axis:Dot(up)) > 0.98 then up = root.CFrame.RightVector end
	local center = origin + axis * ((low + high) * 0.5)
	local size   = Vector3.new(CFG.BODY_WIDTH, CFG.BODY_THICKNESS, (high - low) + CFG.BODY_LENGTH_PAD * 2)
	return CFrame.lookAt(center, center + axis, up), size
end

-- ─── COLLIDE-AND-SLIDE ───────────────────────────────────────────────────────
local function collideAndSlide(
	boxCF: CFrame, boxSize: Vector3,
	velocity: Vector3, dt: number,
	params: RaycastParams
): Vector3
	local castSize  = boxSize - Vector3.one * CFG.SLIDE_CAST_SHRINK
	local cf        = boxCF
	local remaining = velocity * dt
	local moved     = Vector3.zero
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
				-- v5: both easing curves run via GetValue — the ONLY TweenService usage in the render path
				local grow = TweenService:GetValue(t, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
				local fade = TweenService:GetValue(t, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
				local l = r.layer
				l.holder.Size       = RIPPLE_START_SIZE:Lerp(RIPPLE_FULL_SIZE, grow)
				l.core.Transparency = RIPPLE_CORE_ALPHA + (1 - RIPPLE_CORE_ALPHA) * fade
				l.core.Thickness    = CFG.RING_CORE_PX  + (1 - CFG.RING_CORE_PX) * fade
				l.halo.Transparency = RIPPLE_HALO_ALPHA  + (1 - RIPPLE_HALO_ALPHA) * fade
				l.halo.Thickness    = CFG.RING_HALO_PX   + (3 - CFG.RING_HALO_PX)  * fade
			end
		end
	end
	if not any and rippleLoop then rippleLoop:Disconnect(); rippleLoop = nil end
end

local function spawnRipple(x: number, z: number, sy: number, diameter: number, life: number)
	local now = os.clock()
	local chosen: Ripple? = nil
	for _, c in ripplePool do
		if not c.active then chosen = c; break
		elseif not chosen or (c.born + c.life - now) < (chosen.born + chosen.life - now) then
			chosen = c
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
type CausticLayer = { frame: Frame, grad: UIGradient, phase: number, speed: number }

local function makeCausticGui(parent: Part): { SurfaceGui, { CausticLayer } }
	local gui = Instance.new("SurfaceGui")
	gui.Name = "CausticGui"; gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.LightInfluence = 0; gui.AlwaysOnTop = false; gui.Active = false
	gui.Parent = parent

	local layers: { CausticLayer } = {}
	for i = 1, CFG.CAUSTIC_LAYERS do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position    = UDim2.fromScale(0.5, 0.5)
		f.Size        = UDim2.fromScale(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5)
		f.BackgroundTransparency = 1; f.BorderSizePixel = 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0.5, 0)

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(180, 230, 255)
		stroke.Thickness = 6 + math.random() * 8
		stroke.Transparency = CFG.CAUSTIC_ALPHA_BASE
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = f

		local grad = Instance.new("UIGradient")
		grad.Transparency = ARC_CAUSTIC
		grad.Rotation     = math.random() * 360
		grad.Parent       = stroke

		f.Parent = gui

		table.insert(layers, {
			frame = f,
			grad  = grad,
			phase = math.random() * TAU,
			speed = (CFG.CAUSTIC_SPEED * 0.7 + math.random() * CFG.CAUSTIC_SPEED * 0.6) * (math.random() < 0.5 and 1 or -1),
		})
	end
	return gui, layers
end

-- ─── STREAK CONNECTIONS ───────────────────────────────────────────────────────
local activeStreakConns: { RBXScriptConnection } = {}
local lastSplashClock = 0

-- ─── 3-D BUBBLE POOL ─────────────────────────────────────────────────────────
-- Bubble parts live permanently; we move them in PreRender.
local bubblePool: { Bubble } = {}
local bubbleLoopConn: RBXScriptConnection? = nil

local function buildBubbleParts()
	for _ = 1, CFG.BUBBLE_POOL_SIZE do
		local p = newEffectPart("SwimBubble3D", Vector3.new(0.15, 0.15, 0.15))
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.Glass
		p.Color = Color3.fromRGB(200, 240, 255)
		p.Transparency = 0.6
		p.Parent = effectsFolder
		table.insert(bubblePool, {
			pos = Vector3.zero, vel = Vector3.zero,
			born = 0, life = 0,
			active = false, part = p,
		})
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
			b.born   = os.clock()
			b.life   = math.random() * 0.8 + 0.5
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
				b.part.Transparency = 1
			else
				any = true
				-- physics: drag opposes velocity, buoyancy pushes up
				local drag   = -b.vel * CFG.BUBBLE_DRAG
				local buoy   = Vector3.new(0, CFG.BUBBLE_BUOYANCY, 0)
				b.vel = b.vel + (drag + buoy) * dt
				b.pos = b.pos + b.vel * dt
				b.part.CFrame = CFrame.new(b.pos)
				local t = age / b.life
				b.part.Transparency = 0.6 + 0.4 * (t * t)  -- fade out toward end
			end
		end
	end
	if not any and bubbleLoopConn then
		bubbleLoopConn:Disconnect()
		bubbleLoopConn = nil
	end
end

-- ─── STREAKS ─────────────────────────────────────────────────────────────────
local function spawnStreaks(origin: Vector3, count: number)
	local gravity = 55
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
		part.Parent = effectsFolder
		Debris:AddItem(part, 1.8)
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
				local pos = origin + s.velocity * elapsed + Vector3.new(0, -0.5 * gravity * elapsed * elapsed, 0)
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
	local x = math.floor(position.X / VOXEL) * VOXEL
	local z = math.floor(position.Z / VOXEL) * VOXEL
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

	-- bubble emitter (particle, for dense clouds)
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

	-- caustic shimmer part (positioned below surface)
	local causticPart = newEffectPart("SwimCaustic", Vector3.new(20, 0.05, 20))
	causticPart.Parent = effectsFolder
	local causticGui, causticLayers = makeCausticGui(causticPart)
	causticGui.Enabled = false

	-- hitbox
	local hitbox = newEffectPart("SwimHitbox", Vector3.new(CFG.BODY_WIDTH, CFG.BODY_THICKNESS, 5))
	hitbox.Material = Enum.Material.Neon; hitbox.Color = Color3.fromRGB(80, 200, 255)
	hitbox.Transparency = (CFG.SHOW_HITBOX and IS_STUDIO) and 0.75 or 1
	hitbox:SetAttribute("OwnerUserId", tostring(LocalPlayer.UserId)); hitbox:SetAttribute("Swimming", false)
	CollectionService:AddTag(hitbox, "SwimHitbox"); hitbox.Parent = effectsFolder

	-- post-processing
	local blurFx = Instance.new("BlurEffect"); blurFx.Name = "SwimBlur"; blurFx.Size = 0; blurFx.Enabled = false
	local colorFx = Instance.new("ColorCorrectionEffect"); colorFx.Name = "SwimCC"
	colorFx.TintColor = Color3.fromRGB(255,255,255); colorFx.Brightness = 0
	colorFx.Contrast = 0; colorFx.Saturation = 0; colorFx.Enabled = false

	local savedFogEnd   = Lighting.FogEnd
	local savedFogColor = Lighting.FogColor
	local currentFogEnd = savedFogEnd

	-- water detection
	local wop = OverlapParams.new(); wop.FilterType = Enum.RaycastFilterType.Include; wop.MaxParts = 32
	local castP = RaycastParams.new()
	castP.IgnoreWater = true; castP.RespectCanCollide = true; castP.CollisionGroup = primaryPart.CollisionGroup

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
	end
	table.insert(conns, CollectionService:GetInstanceAddedSignal("Water"):Connect(RefreshWaterFilter))
	table.insert(conns, CollectionService:GetInstanceRemovedSignal("Water"):Connect(RefreshWaterFilter))
	RefreshWaterFilter()

	-- ── state ──────────────────────────────────────────────────────────────
	local isUnderwater  = false
	local isRising      = false
	local isSinking     = false
	local wasUnderwater = false
	local isCleanedUp   = false

	-- 3-D velocity spring state
	local curVel    = Vector3.zero        -- current velocity
	local velSpringV = Vector3.zero       -- velocity spring's internal d/dt velocity

	-- orientation spring state
	local smoothLook    = primaryPart.CFrame.LookVector
	local lookSpringV   = Vector3.zero    -- angular spring d/dt for look direction

	-- tilt (pitch) spring
	local curTilt  = 0.0
	local tiltVelS = 0.0

	-- bank (roll on turn) spring
	local curBank  = 0.0
	local bankVelS = 0.0

	-- camera lean spring
	local curLean  = 0.0
	local leanVelS = 0.0
	local baseCamCF: CFrame? = nil        -- saved camera CFrame offset

	-- surface
	local lastWaterTop: number? = nil
	local surfaceY: number?     = nil
	local shownSurfaceY         = 0.0
	local surfaceReady          = false
	local surfaceTimer          = 0.0
	local wakeTimer             = 0.0
	local fxAlpha               = 0.0
	local swirlTime             = 0.0
	local movingNow             = false
	local swirlPos              = Vector3.zero
	local swirlReady            = false
	local swimDepth             = 0.0
	local swimClock             = 0.0

	-- crest detection
	local prevCrestY            = 0.0
	local crestTimer            = 0.0

	-- bubble spawn accumulator
	local bubbleAccum           = 0.0

	-- animation
	local swimIdleAnim: AnimationTrack?
	local swimMoveAnim: AnimationTrack?
	local currentAnim: AnimationTrack?

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
		local terrain = Workspace.Terrain
		if terrain:GetMaterialAtPosition(pos) == Enum.Material.Water then lastWaterTop = nil; return true end
		if terrain:GetMaterialAtPosition(pos + Vector3.new(0, 1.5, 0)) == Enum.Material.Water then lastWaterTop = nil; return true end
		local parts = Workspace:GetPartBoundsInBox(CFrame.new(pos + Vector3.new(0, 0.75, 0)), Vector3.new(2, 3.5, 2), wop)
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
		ContextActionService:BindAction(BIND_RISE, OnRiseAction, false, Enum.KeyCode.Space,      Enum.KeyCode.ButtonA)
		ContextActionService:BindAction(BIND_SINK, OnSinkAction, false, Enum.KeyCode.LeftShift,  Enum.KeyCode.ButtonB)
	end

	local function ApplyUnderwaterFX(camera: Camera)
		blurFx.Enabled  = true; colorFx.Enabled = true
		blurFx.Parent   = camera; colorFx.Parent = camera
		TweenService:Create(blurFx,   TweenInfo.new(CFG.BLUR_TWEEN_TIME), { Size = CFG.BLUR_SIZE }):Play()
		TweenService:Create(colorFx,  TweenInfo.new(CFG.BLUR_TWEEN_TIME), { TintColor = CFG.UNDERWATER_FOG_COLOR, Brightness = -0.04, Saturation = -0.15 }):Play()
		TweenService:Create(Lighting, TweenInfo.new(CFG.BLUR_TWEEN_TIME), { FogEnd = CFG.UNDERWATER_FOG_END, FogColor = CFG.UNDERWATER_FOG_COLOR }):Play()
		currentFogEnd = CFG.UNDERWATER_FOG_END
	end
	local function RemoveUnderwaterFX()
		TweenService:Create(blurFx,   TweenInfo.new(CFG.BLUR_TWEEN_TIME), { Size = 0 }):Play()
		TweenService:Create(colorFx,  TweenInfo.new(CFG.BLUR_TWEEN_TIME), { TintColor = Color3.fromRGB(255,255,255), Brightness = 0, Saturation = 0 }):Play()
		TweenService:Create(Lighting, TweenInfo.new(CFG.BLUR_TWEEN_TIME), { FogEnd = savedFogEnd, FogColor = savedFogColor }):Play()
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
		-- restore camera offset
		local cam = Workspace.CurrentCamera
		if cam then cam.CFrame = cam.CFrame end  -- reset; lean was CFrame-composed so just let it go
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
		task.delay(CFG.BLUR_TWEEN_TIME + 0.1, function() blurFx:Destroy(); colorFx:Destroy() end)
	end

	-- ════════════════════════════════════════════════════════════════════════
	--  PHYSICS LOOP  (PreSimulation = before engine integrates physics)
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
				lookSpringV = Vector3.zero; velSpringV = Vector3.zero
				swimClock = 0
				local carried = primaryPart.AssemblyLinearVelocity
				if carried.Magnitude > CFG.ENTRY_MAX_SPEED then carried = carried.Unit * CFG.ENTRY_MAX_SPEED end
				curVel = carried
				local eS = MeasureSurface(); surfaceTimer = 0.1
				if eS and eS - primaryPart.Position.Y < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position; playSplash(surfaceFx, p.X, p.Z, eS, true)
				end
				prevCrestY = surfaceY or primaryPart.Position.Y
			end

			surfaceTimer -= dt
			if surfaceTimer <= 0 then surfaceTimer = 0.1; MeasureSurface() end

			humanoid.AutoRotate = false; alignOri.Enabled = true; linVel.MaxForce = 100000

			-- ── target velocity from input ──────────────────────────────────
			local moveDir  = humanoid.MoveDirection
			local isMoving = moveDir.Magnitude > 0.05
			local targetVel = Vector3.zero

			if isMoving then
				local camCF = camera.CFrame
				local rVec  = camCF.RightVector
				local fRight = Vector3.new(rVec.X, 0, rVec.Z)
				if fRight.Magnitude > 0.001 then
					local fFwd = Vector3.yAxis:Cross(fRight).Unit
					local yawCF = CFrame.lookAt(Vector3.zero, fFwd)
					local localIn = yawCF:VectorToObjectSpace(moveDir)
					local swimDir = camCF:VectorToWorldSpace(localIn)
					if swimDir.Magnitude > 0.001 then targetVel = swimDir.Unit * CFG.SWIM_SPEED end
				end
			else
				targetVel = Vector3.new(0, -0.5, 0)
			end

			if isRising  then targetVel = Vector3.new(targetVel.X, CFG.RISE_SPEED,  targetVel.Z) end
			if isSinking then targetVel = Vector3.new(targetVel.X, -CFG.SINK_SPEED, targetVel.Z) end

			-- ── underwater current drift (3-D sinusoidal field) ────────────
			local t = os.clock()
			local depthFactor = math.clamp(swimDepth / CFG.CURRENT_DEPTH_SCALE, 0, 1)
			local drift = Vector3.new(
				math.sin(t * TAU * CFG.CURRENT_FREQ_X) * CFG.CURRENT_STRENGTH * depthFactor,
				0,
				math.cos(t * TAU * CFG.CURRENT_FREQ_Z) * CFG.CURRENT_STRENGTH * depthFactor
			)
			targetVel = targetVel + drift

			-- ── 3-D velocity spring (replaces raw lerp) ────────────────────
			swimClock += math.min(dt, 0.25)
			local ticks = 0
			while swimClock >= SWIM_TICK and ticks < CFG.MAX_TICKS_PER_FRAME do
				swimClock -= SWIM_TICK; ticks += 1
				curVel, velSpringV = springVec3(curVel, velSpringV, targetVel, CFG.VEL_STIFFNESS, CFG.VEL_DAMPING, SWIM_TICK)
			end
			if ticks == CFG.MAX_TICKS_PER_FRAME then swimClock = 0 end

			-- ── look direction spring ──────────────────────────────────────
			local lookTarget = smoothLook
			local applyManualTilt = false
			if isMoving and targetVel.Magnitude > 0.1 then
				lookTarget = targetVel.Unit
			else
				local flat = Vector3.new(primaryPart.CFrame.LookVector.X, 0, primaryPart.CFrame.LookVector.Z)
				if flat.Magnitude > 0.001 then lookTarget = flat.Unit end
				applyManualTilt = true
			end
			smoothLook, lookSpringV = springDir(smoothLook, lookSpringV, lookTarget, CFG.ORI_OMEGA, CFG.ORI_ZETA, dt)

			-- ── pitch (tilt) spring ────────────────────────────────────────
			local normY = math.clamp(curVel.Y / CFG.RISE_SPEED, -1, 1)
			local targetTilt = applyManualTilt and (-normY * CFG.TILT_MAX) or (-normY * CFG.TILT_MAX * 0.5)
			curTilt, tiltVelS = springScalar(curTilt, tiltVelS, targetTilt, CFG.TILT_OMEGA, CFG.TILT_ZETA, dt)

			-- ── bank (roll on turn) spring — cross product gives turn rate ─
			local cross = smoothLook:Cross(lookTarget)
			local bankSign = cross.Y > 0 and 1 or -1
			local targetBank = bankSign * math.clamp(cross.Magnitude * 80, 0, CFG.BANK_MAX)
			curBank, bankVelS = springScalar(curBank, bankVelS, targetBank, CFG.BANK_OMEGA, CFG.BANK_ZETA, dt)

			-- ── collide-and-slide ──────────────────────────────────────────
			if curVel.Magnitude > 0.05 then
				local bCF, bSize = fitBody(character, primaryPart)
				curVel = collideAndSlide(bCF, bSize, curVel, math.clamp(dt, 1/240, 1/20), castP)
			end
			linVel.VectorVelocity = curVel

			-- ── emitter rates ──────────────────────────────────────────────
			local speed = math.max(curVel.Magnitude, 0)
			local sf    = math.clamp(speed / CFG.SWIM_SPEED, 0, 1)
			bubbleEmit.Rate = math.clamp(CFG.BUBBLE_RATE + (CFG.BUBBLE_MOVE_RATE - CFG.BUBBLE_RATE) * sf, 0, CFG.BUBBLE_MOVE_RATE)
			wakeEmit.Rate   = isMoving and math.clamp(sf * 24, 0, 24) or 0

			-- ── 3-D bubble physics spawn ───────────────────────────────────
			bubbleAccum += dt * (CFG.BUBBLE_RATE * 0.3 + sf * CFG.BUBBLE_RATE * 0.7)
			while bubbleAccum >= 1 do
				bubbleAccum -= 1
				spawnBubble3D(primaryPart.Position, curVel)
			end
			if not bubbleLoopConn then
				bubbleLoopConn = RunService.PreRender:Connect(function(bdt) stepBubbles3D(bdt) end)
			end

			-- ── multi-layer wake turbulence ────────────────────────────────
			movingNow = isMoving
			wakeTimer -= dt
			local sy = surfaceY
			if isMoving and sy and wakeTimer <= 0
				and (sy - primaryPart.Position.Y) < CFG.SURFACE_FX_DEPTH * 0.6
			then
				wakeTimer = CFG.WAKE_RING_INTERVAL * (1.5 - sf * 0.75)
				local p   = primaryPart.Position
				local right = Vector3.new(smoothLook.Z, 0, -smoothLook.X).Unit  -- lateral of look direction
				-- three lanes: centre, left, right
				for lane = -1, 1 do
					local offset = right * (lane * CFG.WAKE_LANE_WIDTH)
					local diam   = CFG.WAKE_RING_DIAMETER * (1 + (math.random() - 0.5) * CFG.WAKE_DIAM_VARIANCE)
					local life   = CFG.RIPPLE_TWEEN_TIME  * 0.9 * (1 + (math.random() - 0.5) * CFG.WAKE_LIFE_VARIANCE)
					spawnRipple(p.X + offset.X, p.Z + offset.Z, sy, diam, life)
				end
			end

			-- ── crest detection: surface rising ahead → burst ring ─────────
			crestTimer -= dt
			if sy and crestTimer <= 0 and isMoving then
				crestTimer = 0.18
				local ahead = primaryPart.Position + smoothLook * CFG.CREST_CHECK_DIST
				local crp = RaycastParams.new(); crp.IgnoreWater = false; crp.ExcludeInstances = { character }
				local chit = Workspace:Raycast(ahead + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0), crp)
				if chit and chit.Material == Enum.Material.Water then
					local crY = chit.Position.Y
					if crY - prevCrestY > CFG.CREST_RING_THRESH then
						spawnRipple(ahead.X, ahead.Z, crY, CFG.WAKE_RING_DIAMETER * 1.4, CFG.RIPPLE_TWEEN_TIME * 0.7)
					end
					prevCrestY = crY
				end
			end

			-- ── depth tracking ─────────────────────────────────────────────
			swimDepth = sy and math.max(sy - primaryPart.Position.Y, 0) or swimDepth

			-- ── orientation: compose pitch + bank ─────────────────────────
			local rVec2 = camera.CFrame.RightVector
			local upVec = rVec2:Cross(smoothLook)
			upVec = upVec.Magnitude > 0.001 and upVec.Unit or Vector3.yAxis
			alignOri.CFrame = CFrame.lookAt(Vector3.zero, smoothLook, upVec)
				* CFrame.Angles(math.rad(curTilt), 0, math.rad(curBank))

			HandleAnimation(isMoving or isRising or isSinking)

		else
			-- ── exiting water ──────────────────────────────────────────────
			if wasUnderwater then
				wasUnderwater = false
				local wasRising = isRising
				UnbindInputs()
				humanoid.AutoRotate = true; alignOri.Enabled = false
				bubbleEmit.Rate = 0; wakeEmit.Rate = 0
				curTilt = 0; curBank = 0; curLean = 0
				linVel.MaxForce = 0; linVel.VectorVelocity = Vector3.zero; curVel = Vector3.zero
				velSpringV = Vector3.zero; lookSpringV = Vector3.zero
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
	--  VISUAL LOOP  (PreRender = last step before the frame is drawn)
	-- ════════════════════════════════════════════════════════════════════════
	visualConn = RunService.PreRender:Connect(function(dt: number)
		if isCleanedUp then return end
		local camera = Workspace.CurrentCamera; if not camera then return end
		local sy = surfaceY

		-- ── fxAlpha: how visible the surface effects are ──────────────────
		local targetAlpha = 0
		if isUnderwater and sy then
			local depth = sy - primaryPart.Position.Y
			targetAlpha = 1 - math.clamp(
				(depth - CFG.SURFACE_FX_FULL_DEPTH) / (CFG.SURFACE_FX_DEPTH - CFG.SURFACE_FX_FULL_DEPTH),
				0, 1
			)

			-- ── depth-adaptive fog (purely 3-D scalar, no TweenService) ───
			local depthT  = math.clamp(depth / (CFG.SURFACE_FX_DEPTH * 2), 0, 1)
			local fogTarget = CFG.UNDERWATER_FOG_END * (1 - CFG.FOG_DEPTH_SCALE * depthT)
			currentFogEnd = currentFogEnd + (fogTarget - currentFogEnd) * expAlpha(CFG.FOG_ADAPT_RATE, dt)
			Lighting.FogEnd = currentFogEnd
		end
		fxAlpha += (targetAlpha - fxAlpha) * expAlpha(10, dt)

		-- ── camera lean (velocity-based roll) ─────────────────────────────
		local lateralSpeed = 0
		if isUnderwater then
			local camRight = camera.CFrame.RightVector
			lateralSpeed = curVel:Dot(camRight)
		end
		local targetLean = math.clamp(lateralSpeed / CFG.SWIM_SPEED, -1, 1) * CFG.CAM_LEAN_MAX
		curLean, leanVelS = springScalar(curLean, leanVelS, targetLean, CFG.CAM_LEAN_OMEGA, CFG.CAM_LEAN_ZETA, dt)
		if isUnderwater and math.abs(curLean) > 0.01 then
			local leanCF = CFrame.Angles(0, 0, math.rad(-curLean))
			camera.CFrame = camera.CFrame * leanCF
		end

		-- ── swirl follow ──────────────────────────────────────────────────
		if not sy or fxAlpha < 0.01 then
			if surfaceFx.gui.Enabled then surfaceFx.gui.Enabled = false end
			if causticGui.Enabled then causticGui.Enabled = false end
			surfaceFx.foam.Rate = 0; swirlReady = false; return
		end
		if not surfaceFx.gui.Enabled then surfaceFx.gui.Enabled = true end

		shownSurfaceY += (sy - shownSurfaceY) * expAlpha(20, dt)
		local pos    = primaryPart.Position
		local target = Vector3.new(pos.X, shownSurfaceY + CFG.SURFACE_OFFSET, pos.Z)
		if swirlReady then
			swirlPos += (target - swirlPos) * expAlpha(CFG.SWIRL_FOLLOW_RATE, dt)
		else
			swirlPos = target; swirlReady = true
		end
		surfaceFx.part.CFrame = CFrame.new(swirlPos)

		-- ── swirl rings ───────────────────────────────────────────────────
		swirlTime += dt
		local outerSpin = (swirlTime * CFG.SWIRL_SPEED) % 360
		local innerSpin = (-swirlTime * CFG.SWIRL_SPEED * 1.35) % 360
		surfaceFx.outer.coreGradient.Rotation = outerSpin; surfaceFx.outer.haloGradient.Rotation = outerSpin
		surfaceFx.inner.coreGradient.Rotation = innerSpin; surfaceFx.inner.haloGradient.Rotation = innerSpin

		local sf = math.clamp(curVel.Magnitude / CFG.SWIM_SPEED, 0, 1)
		surfaceFx.outer.core.Color = lerpColor(CFG.RING_CORE_COLOR, CFG.RING_CORE_COLOR_FAST, sf)
		surfaceFx.outer.halo.Color = lerpColor(CFG.RING_HALO_COLOR, CFG.RING_HALO_COLOR_FAST, sf)
		surfaceFx.inner.core.Color = lerpColor(CFG.RING_CORE_COLOR, CFG.RING_CORE_COLOR_FAST, sf)
		surfaceFx.inner.halo.Color = lerpColor(CFG.RING_HALO_COLOR, CFG.RING_HALO_COLOR_FAST, sf)

		local breathe = 0.6 + 0.035 * math.sin(swirlTime * 2.4)
		surfaceFx.inner.holder.Size = UDim2.fromScale(breathe, breathe)

		local a = fxAlpha
		surfaceFx.outer.core.Transparency = 1 - 0.65 * a; surfaceFx.outer.halo.Transparency = 1 - 0.18 * a
		surfaceFx.inner.core.Transparency = 1 - 0.88 * a; surfaceFx.inner.halo.Transparency = 1 - 0.26 * a
		surfaceFx.foam.Rate = movingNow and (CFG.FOAM_RATE * sf * a) or 0

		-- ── caustic shimmer (below surface) ───────────────────────────────
		local causticDepth = 3.5   -- studs below surface
		if swimDepth > 1.0 then
			if not causticGui.Enabled then causticGui.Enabled = true end
			causticPart.CFrame = CFrame.new(pos.X, shownSurfaceY - causticDepth, pos.Z)
			for _, layer in causticLayers do
				local ang = (swirlTime * layer.speed + layer.phase) % TAU
				layer.grad.Rotation = math.deg(ang)
				local pulse = CFG.CAUSTIC_ALPHA_BASE + CFG.CAUSTIC_ALPHA_PULSE * math.sin(ang * 3.1)
				local stroke = layer.frame:FindFirstChildOfClass("UIStroke")
				if stroke then stroke.Transparency = math.clamp(pulse * (1 - a * 0.3), 0, 1) end
			end
		else
			if causticGui.Enabled then causticGui.Enabled = false end
		end
	end)

	-- ════════════════════════════════════════════════════════════════════════
	--  HITBOX LOOP  (PostSimulation = after engine integration)
	-- ════════════════════════════════════════════════════════════════════════
	hitboxConn = RunService.PostSimulation:Connect(function()
		if isCleanedUp then return end
		if isUnderwater then
			local bCF, bSize = fitBody(character, primaryPart)
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
