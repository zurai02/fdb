--!strict
--!optimize 2
-- Swim controller v3
-- Thin glowing ring ripples (vector UIStroke circles), a swirl ring that follows you at the surface,
-- foam puffs and curved splash streaks.
-- v2: ripples are pooled and advanced by one RunService.PreRender loop with TweenService:GetValue
-- easing (no per-ripple instances or tweens), splash streaks run on PreRender, and the swirl
-- follows you with Vector3 smoothing.
-- v3: swim steering (speed, turning, tilt) runs on a fixed 120 Hz tick, so it behaves the same at any frame
-- rate. Roblox runs scripts once per rendered frame, so the tick cannot beat the frame rate; the engine
-- integrates physics at up to 240 Hz. The body is swept against walls (collide and slide) using a box fitted
-- to the pose you are really swimming in, and that box is exposed as a tagged SwimHitbox part.

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer

local CFG = {
	-- movement
	SWIM_SPEED            = 22,
	RISE_SPEED            = 16,
	SINK_SPEED            = 16,
	TILT_MAX              = 38,
	TILT_RATE             = 12,
	ALIGN_RESPONSIVENESS  = 25,
	VELOCITY_HALFLIFE     = 12,

	-- underwater look
	BLUR_SIZE             = 8,
	BLUR_TWEEN_TIME       = 0.35,
	UNDERWATER_FOG_END    = 80,
	UNDERWATER_FOG_COLOR  = Color3.fromRGB(30, 90, 160),
	BUBBLE_RATE           = 18,
	BUBBLE_MOVE_RATE      = 36,

	-- surface ripples: thin glowing rings (diameters in studs, line widths in canvas pixels)
	RING_CORE_COLOR       = Color3.fromRGB(214, 244, 255),
	RING_HALO_COLOR       = Color3.fromRGB(140, 205, 255),
	RING_CORE_PX          = 3,    -- bright hairline
	RING_HALO_PX          = 10,   -- soft glow around it
	RIPPLE_TWEEN_TIME     = 1.0,
	ENTRY_RING_DIAMETER   = 16,
	WAKE_RING_DIAMETER    = 9,
	WAKE_RING_INTERVAL    = 0.32,
	SWIRL_DIAMETER        = 8,    -- ring that follows you at the surface
	SWIRL_SPEED           = 70,   -- degrees/sec the swirl arcs orbit
	SWIRL_FOLLOW_RATE     = 60,   -- how tightly the swirl tracks you (higher = tighter)
	RIPPLE_POOL_SIZE      = 14,   -- ripple rings built once and reused

	-- foam puffs and splash
	FOAM_TEXTURE          = "rbxasset://textures/particles/smoke_main.dds",
	DROP_TEXTURE          = "rbxassetid://243660364",
	FOAM_RATE             = 10,
	SPLASH_PUFFS          = 12,
	SPLASH_DROPS          = 10,
	SPLASH_STREAKS        = 8,

	-- surface placement
	SURFACE_OFFSET        = 0.12, -- studs above the water so rings never z-fight with it
	SURFACE_FX_FULL_DEPTH = 2.5,  -- swirl + foam fully visible above this depth
	SURFACE_FX_DEPTH      = 7,    -- ...and fade out by this depth
	ENTRY_MAX_DEPTH       = 6,    -- no splash if you appear deeper than this

	-- swim simulation: fixed tick, so movement feels the same at 30, 60, 144 or 240 fps
	SWIM_TICK_RATE        = 120,   -- steering ticks per second
	MAX_TICKS_PER_FRAME   = 12,    -- after a hitch the backlog is dropped instead of replayed
	LOOK_TURN_RATE        = 14,    -- how fast the body turns toward the swim direction
	ENTRY_MAX_SPEED       = 60,    -- momentum carried into the water when you dive in (studs/s)

	-- body hitbox + wall sliding
	BODY_WIDTH            = 2.2,   -- studs, side to side
	BODY_THICKNESS        = 1.8,   -- studs, top to bottom (under the 2 stud root so you can rest on the floor)
	BODY_LENGTH_PAD       = 0.2,   -- studs added past the head and feet
	SLIDE_SKIN            = 0.12,  -- gap kept between the body and a wall
	SLIDE_CAST_SHRINK     = 0.1,   -- sweep box is slightly smaller than the hitbox so it never starts inside a wall
	SLIDE_MAX_BOUNCES     = 3,
	SHOW_HITBOX           = false, -- true draws the hitbox so you can tune the sizes above

	FALLBACK_IDLE_ANIM    = "rbxassetid://913384386",
	FALLBACK_SWIM_ANIM    = "rbxassetid://913389033",
}

local BIND_RISE = "CustomSwim_Rise"
local BIND_SINK = "CustomSwim_Sink"

local SWIM_TICK           = 1 / CFG.SWIM_TICK_RATE
local TICK_VELOCITY_ALPHA = 1 - math.exp(-CFG.VELOCITY_HALFLIFE * SWIM_TICK)
local TICK_TILT_ALPHA     = 1 - math.exp(-CFG.TILT_RATE * SWIM_TICK)
local TICK_LOOK_ALPHA     = 1 - math.exp(-CFG.LOOK_TURN_RATE * SWIM_TICK)

local VOXEL       = 4
local RING_CANVAS = 384
local RING_MARGIN = 14

-- Transparency patterns that break a ring into swirling arcs
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

type Streak = {
	part: Part,
	trail: Trail,
	velocity: Vector3,
	active: boolean,
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

local lastSplashClock = 0

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function expDecayAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * math.min(dt, 0.1))
end

local BODY_PART_NAMES = {
	"Head", "UpperTorso", "LowerTorso", "LeftHand", "RightHand", "LeftFoot", "RightFoot",
	"Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg",
}

-- Turns one direction toward another and never collapses through zero.
local function blendDirection(from: Vector3, to: Vector3, alpha: number): Vector3
	local mixed = from:Lerp(to, alpha)
	if mixed.Magnitude < 0.05 then
		return to
	end
	return mixed.Unit
end

-- Fits an oriented box around the body as it is posed right now (R15 and R6). The swim animation lays the
-- body down while the root part stays upright, so the hitbox and the wall sweep follow the real pose.
local function fitBody(character: Model, root: BasePart): (CFrame, Vector3)
	local origin = root.Position
	local axis = root.CFrame.LookVector

	local head = character:FindFirstChild("Head")
	local pelvis = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	if head and pelvis and head:IsA("BasePart") and pelvis:IsA("BasePart") then
		local spine = head.Position - pelvis.Position
		if spine.Magnitude > 0.5 then
			axis = spine.Unit
		end
	end

	local low, high = -1.0, 1.0
	for _, name in BODY_PART_NAMES do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local along = (part.Position - origin):Dot(axis)
			low = math.min(low, along - 0.5)
			high = math.max(high, along + 0.5)
		end
	end

	local up = Vector3.yAxis
	if math.abs(axis:Dot(up)) > 0.98 then
		up = root.CFrame.RightVector
	end

	local center = origin + axis * ((low + high) * 0.5)
	local size = Vector3.new(CFG.BODY_WIDTH, CFG.BODY_THICKNESS, (high - low) + CFG.BODY_LENGTH_PAD * 2)
	return CFrame.lookAt(center, center + axis, up), size
end

-- Moves a box along velocity * dt, stopping at walls and sliding along them. Returns the velocity that
-- actually fits (distance moved / dt), so the physics is never asked to press into a surface.
local function collideAndSlide(boxCF: CFrame, boxSize: Vector3, velocity: Vector3, dt: number, params: RaycastParams): Vector3
	local castSize = boxSize - Vector3.one * CFG.SLIDE_CAST_SHRINK
	local cf = boxCF
	local remaining = velocity * dt
	local moved = Vector3.zero

	for _ = 1, CFG.SLIDE_MAX_BOUNCES do
		local distance = remaining.Magnitude
		if distance < 1e-4 then
			break
		end

		local direction = remaining / distance
		local hit = Workspace:Blockcast(cf, castSize, direction * (distance + CFG.SLIDE_SKIN), params)
		if not hit then
			moved += remaining
			break
		end

		-- travel up to the wall, keeping a skin gap measured straight off the surface (not along the path),
		-- then keep only the motion that runs along it
		local approach = math.max(-direction:Dot(hit.Normal), 0.1)
		local travel = math.clamp(hit.Distance - CFG.SLIDE_SKIN / approach, 0, distance)
		local step = direction * travel
		moved += step
		cf += step

		local leftover = remaining - step
		remaining = leftover - hit.Normal * leftover:Dot(hit.Normal)
	end

	return moved / dt
end

local function newEffectPart(name: string, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name         = name
	part.Size         = size
	part.Transparency = 1
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CanTouch     = false
	part.CastShadow   = false
	return part
end

local function newEmitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	local target: any = emitter
	for key, value in props do
		target[key] = value
	end
	emitter.Parent = parent
	return emitter
end

local function newRingGui(part: Part): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name           = "RingGui"
	gui.Face           = Enum.NormalId.Top
	gui.SizingMode     = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize     = Vector2.new(RING_CANVAS, RING_CANVAS)
	gui.LightInfluence = 0
	gui.AlwaysOnTop    = false
	gui.Active         = false
	gui.Parent         = part
	return gui
end

-- One ring = a bright thin stroke on top of a wider, fainter stroke (the soft glow).
local function buildRingLayer(
	parent: Instance,
	coreThickness: number,
	haloThickness: number,
	coreTransparency: number,
	haloTransparency: number,
	pattern: NumberSequence
): RingLayer
	local holder = Instance.new("Frame")
	holder.Name                   = "RingLayer"
	holder.AnchorPoint            = Vector2.new(0.5, 0.5)
	holder.Position               = UDim2.fromScale(0.5, 0.5)
	holder.Size                   = UDim2.new(1, -RING_MARGIN * 2, 1, -RING_MARGIN * 2)
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel        = 0
	holder.Parent                 = parent

	local function circle(name: string, color: Color3, thickness: number, transparency: number): (UIStroke, UIGradient)
		local frame = Instance.new("Frame")
		frame.Name                   = name
		frame.AnchorPoint            = Vector2.new(0.5, 0.5)
		frame.Position               = UDim2.fromScale(0.5, 0.5)
		frame.Size                   = UDim2.fromScale(1, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel        = 0
		frame.Parent                 = holder

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent       = frame

		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color           = color
		stroke.Thickness       = thickness
		stroke.Transparency    = transparency
		stroke.Parent          = frame

		local gradient = Instance.new("UIGradient")
		gradient.Transparency = pattern
		gradient.Parent       = stroke

		return stroke, gradient
	end

	local halo, haloGradient = circle("Halo", CFG.RING_HALO_COLOR, haloThickness, haloTransparency)
	local core, coreGradient = circle("Core", CFG.RING_CORE_COLOR, coreThickness, coreTransparency)

	return {
		holder       = holder,
		core         = core,
		halo         = halo,
		coreGradient = coreGradient,
		haloGradient = haloGradient,
	}
end

-- Ripple pool: every ring is built once and reused, so spawning a ripple creates no instances and
-- leaves nothing to clean up. One RunService.PreRender loop advances all live ripples, and
-- TweenService:GetValue supplies the easing, so growth and fade stay smooth at any frame rate.
local RIPPLE_START_SCALE = 0.08
local RIPPLE_START_SIZE  = UDim2.fromScale(RIPPLE_START_SCALE, RIPPLE_START_SCALE)
local RIPPLE_FULL_SIZE   = UDim2.new(1, -RING_MARGIN * 2, 1, -RING_MARGIN * 2)
local RIPPLE_CORE_ALPHA  = 0.05  -- starting transparency of the bright hairline
local RIPPLE_HALO_ALPHA  = 0.72  -- starting transparency of the soft glow
local RIPPLE_LAYER_STEP  = 0.005 -- each pooled ring sits a hair higher so crossing rings never z-fight

local effectsFolder = Instance.new("Folder")
effectsFolder.Name   = "SwimEffects"
effectsFolder.Parent = Workspace

local ripplePool: { Ripple } = {}
local rippleLoop: RBXScriptConnection? = nil

local function buildRipple(index: number): Ripple
	local part = newEffectPart("SwimRipple", Vector3.new(8, 0.05, 8))
	local gui  = newRingGui(part)
	gui.Enabled = false

	local layer = buildRingLayer(gui, CFG.RING_CORE_PX, CFG.RING_HALO_PX, RIPPLE_CORE_ALPHA, RIPPLE_HALO_ALPHA, ARC_PAIR)
	part.Parent = effectsFolder

	return {
		part   = part,
		gui    = gui,
		layer  = layer,
		active = false,
		born   = 0,
		life   = 1,
		bias   = index * RIPPLE_LAYER_STEP,
	}
end

for index = 1, CFG.RIPPLE_POOL_SIZE do
	table.insert(ripplePool, buildRipple(index))
end

local function stepRipples()
	local now = os.clock()
	local anyActive = false

	for _, ripple in ripplePool do
		if ripple.active then
			local t = (now - ripple.born) / ripple.life
			if t >= 1 then
				ripple.active      = false
				ripple.gui.Enabled = false
			else
				anyActive = true
				local grow  = TweenService:GetValue(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				local fade  = TweenService:GetValue(t, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
				local layer = ripple.layer
				layer.holder.Size       = RIPPLE_START_SIZE:Lerp(RIPPLE_FULL_SIZE, grow)
				layer.core.Transparency = lerp(RIPPLE_CORE_ALPHA, 1, fade)
				layer.core.Thickness    = lerp(CFG.RING_CORE_PX, 1, fade)
				layer.halo.Transparency = lerp(RIPPLE_HALO_ALPHA, 1, fade)
				layer.halo.Thickness    = lerp(CFG.RING_HALO_PX, 3, fade)
			end
		end
	end

	if not anyActive and rippleLoop then
		rippleLoop:Disconnect()
		rippleLoop = nil
	end
end

-- Expanding thin ripple ring that fades out (diameter in studs, lifetime in seconds).
local function spawnRipple(x: number, z: number, surfaceY: number, diameter: number, lifetime: number)
	-- take a free ring; if every ring is busy, recycle the oldest live one
	local chosen: Ripple? = nil
	for _, candidate in ripplePool do
		if not candidate.active then
			chosen = candidate
			break
		elseif chosen == nil or candidate.born < chosen.born then
			chosen = candidate
		end
	end
	if not chosen then return end
	local ripple: Ripple = chosen

	ripple.active = true
	ripple.born   = os.clock()
	ripple.life   = lifetime

	ripple.part.Size   = Vector3.new(diameter, 0.05, diameter)
	ripple.part.CFrame = CFrame.new(x, surfaceY + CFG.SURFACE_OFFSET + ripple.bias, z)

	local layer = ripple.layer
	layer.holder.Size       = RIPPLE_START_SIZE
	layer.core.Transparency = RIPPLE_CORE_ALPHA
	layer.core.Thickness    = CFG.RING_CORE_PX
	layer.halo.Transparency = RIPPLE_HALO_ALPHA
	layer.halo.Thickness    = CFG.RING_HALO_PX

	local spin = math.random() * 360
	layer.coreGradient.Rotation = spin
	layer.haloGradient.Rotation = spin

	ripple.gui.Enabled = true

	if not rippleLoop then
		rippleLoop = RunService.PreRender:Connect(stepRipples)
	end
end

script.Destroying:Connect(function()
	if rippleLoop then
		rippleLoop:Disconnect()
		rippleLoop = nil
	end
	effectsFolder:Destroy()
end)

-- Thin curved white streaks that fly out of the splash (like the speed arcs in the reference).
local function spawnStreaks(origin: Vector3, count: number)
	local gravity = 55
	local streaks: { Streak } = {}

	for i = 1, count do
		local angle      = (i / count) * math.pi * 2 + (math.random() - 0.5) * 0.7
		local horizontal = 6 + math.random() * 7
		local vertical   = 12 + math.random() * 9

		local part = newEffectPart("SplashStreak", Vector3.one * 0.2)
		part.CFrame = CFrame.new(origin)

		local top = Instance.new("Attachment")
		top.Position = Vector3.new(0, 0.06, 0)
		top.Parent   = part

		local bottom = Instance.new("Attachment")
		bottom.Position = Vector3.new(0, -0.06, 0)
		bottom.Parent   = part

		local trail = Instance.new("Trail")
		trail.Attachment0    = top
		trail.Attachment1    = bottom
		trail.Lifetime       = 0.32
		trail.MinLength      = 0.05
		trail.FaceCamera     = true
		trail.LightEmission  = 0.8
		trail.LightInfluence = 0
		trail.Color          = ColorSequence.new(Color3.fromRGB(255, 255, 255), CFG.RING_HALO_COLOR)
		trail.Transparency   = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.WidthScale     = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.Parent = part

		part.Parent = effectsFolder
		Debris:AddItem(part, 1.8)

		table.insert(streaks, {
			part     = part,
			trail    = trail,
			velocity = Vector3.new(math.cos(angle) * horizontal, vertical, math.sin(angle) * horizontal),
			active   = true,
		})
	end

	local elapsed = 0
	local connection: RBXScriptConnection? = nil
	connection = RunService.PreRender:Connect(function(dt: number)
		elapsed += dt
		local anyActive = false

		for _, s in streaks do
			if s.active then
				local pos = origin + s.velocity * elapsed + Vector3.new(0, -0.5 * gravity * elapsed * elapsed, 0)
				if pos.Y < origin.Y - 0.1 or elapsed > 1.5 then
					s.active = false
					s.trail.Enabled = false
				else
					s.part.CFrame = CFrame.new(pos)
					anyActive = true
				end
			end
		end

		if not anyActive and connection then
			connection:Disconnect()
			connection = nil
		end
	end)
end

-- Persistent carrier that sits on the water surface under you: swirl rings + foam + splash emitters.
local function makeSurfaceFx(): SurfaceFx
	local part = newEffectPart("SwimSurfaceFx", Vector3.new(CFG.SWIRL_DIAMETER, 0.05, CFG.SWIRL_DIAMETER))
	local gui  = newRingGui(part)
	gui.Enabled = false

	local outer = buildRingLayer(gui, 3, 12, 0.35, 0.82, ARC_COMET)
	local inner = buildRingLayer(gui, 4, 14, 0.12, 0.74, ARC_PAIR)
	inner.holder.Size = UDim2.fromScale(0.6, 0.6)

	local attachment = Instance.new("Attachment")
	attachment.Name   = "FoamAttachment"
	attachment.Parent = part

	-- Foam that trails behind you while you swim at the surface
	local foam = newEmitter(attachment, {
		Name              = "Foam",
		Texture           = CFG.FOAM_TEXTURE,
		Color             = ColorSequence.new(Color3.fromRGB(250, 253, 255), Color3.fromRGB(165, 215, 248)),
		Size              = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.6),
			NumberSequenceKeypoint.new(0.4, 1.9),
			NumberSequenceKeypoint.new(1,   2.6),
		}),
		Transparency      = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    0.5),
			NumberSequenceKeypoint.new(0.35, 0.45),
			NumberSequenceKeypoint.new(1,    1),
		}),
		Lifetime          = NumberRange.new(0.7, 1.2),
		Speed             = NumberRange.new(0.5, 2.5),
		SpreadAngle       = Vector2.new(85, 85),
		EmissionDirection = Enum.NormalId.Top,
		Rotation          = NumberRange.new(0, 360),
		RotSpeed          = NumberRange.new(-45, 45),
		Drag              = 1.5,
		LightEmission     = 0.2,
		LightInfluence    = 0.3,
		Rate              = 0,
	})

	-- Big cloud puffs for the entry splash
	local burstPuffs = newEmitter(attachment, {
		Name              = "SplashPuffs",
		Texture           = CFG.FOAM_TEXTURE,
		Color             = ColorSequence.new(Color3.fromRGB(252, 254, 255), Color3.fromRGB(170, 218, 250)),
		Size              = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    1.2),
			NumberSequenceKeypoint.new(0.25, 3.2),
			NumberSequenceKeypoint.new(1,    4.8),
		}),
		Transparency      = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    0.25),
			NumberSequenceKeypoint.new(0.45, 0.4),
			NumberSequenceKeypoint.new(1,    1),
		}),
		Lifetime          = NumberRange.new(0.6, 1.0),
		Speed             = NumberRange.new(10, 18),
		SpreadAngle       = Vector2.new(48, 48),
		EmissionDirection = Enum.NormalId.Top,
		Rotation          = NumberRange.new(0, 360),
		RotSpeed          = NumberRange.new(-60, 60),
		Drag              = 5,
		LightEmission     = 0.2,
		LightInfluence    = 0.3,
		Rate              = 0,
	})

	-- Small droplets that arc up and fall back
	local burstDrops = newEmitter(attachment, {
		Name              = "SplashDrops",
		Texture           = CFG.DROP_TEXTURE,
		Color             = ColorSequence.new(Color3.fromRGB(235, 248, 255)),
		Size              = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		Transparency      = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.05),
			NumberSequenceKeypoint.new(0.7, 0.3),
			NumberSequenceKeypoint.new(1,   1),
		}),
		Lifetime          = NumberRange.new(0.6, 1.1),
		Speed             = NumberRange.new(12, 22),
		SpreadAngle       = Vector2.new(38, 38),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration      = Vector3.new(0, -55, 0),
		LightEmission     = 0.4,
		Rate              = 0,
	})

	part.Parent = effectsFolder

	return {
		part       = part,
		gui        = gui,
		outer      = outer,
		inner      = inner,
		foam       = foam,
		burstPuffs = burstPuffs,
		burstDrops = burstDrops,
	}
end

-- Water surface height. Reads the terrain voxel column above you (exact fill level),
-- with a raycast fallback. Returns nil when it can't be found (effects then skip).
local function findTerrainSurfaceY(position: Vector3): number?
	local layers = 10
	local x = math.floor(position.X / VOXEL) * VOXEL
	local z = math.floor(position.Z / VOXEL) * VOXEL
	local y = (math.floor(position.Y / VOXEL) - 2) * VOXEL

	local region = Region3.new(
		Vector3.new(x, y, z),
		Vector3.new(x + VOXEL, y + layers * VOXEL, z + VOXEL)
	)
	local materials: any, occupancies: any = Workspace.Terrain:ReadVoxels(region, VOXEL)

	local column: any = materials[1]
	local top = 0
	for i = 2, layers do
		if column[i][1] == Enum.Material.Water then
			top = i
		elseif top > 0 then
			break
		end
	end

	if top == 0 or top == layers then
		return nil
	end

	local occupancy: number = occupancies[1][top][1]
	return y + (top - 1) * VOXEL + occupancy * VOXEL
end

local function getSurfaceY(root: BasePart, character: Model, waterTop: number?): number?
	if waterTop then
		return waterTop
	end

	local terrainY = findTerrainSurfaceY(root.Position)
	if terrainY then
		return terrainY
	end

	local params = RaycastParams.new()
	params.ExcludeInstances = { character }
	params.IgnoreWater = false
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, 80, 0), params)
	if hit and hit.Material == Enum.Material.Water then
		return hit.Position.Y
	end

	return nil
end

local function playSplash(fx: SurfaceFx, x: number, z: number, surfaceY: number, big: boolean)
	local now = os.clock()
	if now - lastSplashClock < 0.5 then return end
	lastSplashClock = now

	local scale = big and 1 or 0.6

	fx.part.CFrame = CFrame.new(x, surfaceY + CFG.SURFACE_OFFSET, z)
	fx.burstPuffs:Emit(math.floor(CFG.SPLASH_PUFFS * scale))
	fx.burstDrops:Emit(math.floor(CFG.SPLASH_DROPS * scale))
	if big then
		spawnStreaks(Vector3.new(x, surfaceY + 0.25, z), CFG.SPLASH_STREAKS)
	end

	local diameter = CFG.ENTRY_RING_DIAMETER * scale
	local life     = CFG.RIPPLE_TWEEN_TIME
	spawnRipple(x, z, surfaceY, diameter, life)
	task.delay(0.12, spawnRipple, x, z, surfaceY, diameter * 0.72, life * 0.9)
	task.delay(0.26, spawnRipple, x, z, surfaceY, diameter * 0.48, life * 0.8)
end

local function SetupCharacter(character: Model)
	local humanoid     = character:WaitForChild("Humanoid") :: Humanoid
	local primaryPart  = (character.PrimaryPart or character:WaitForChild("HumanoidRootPart", 5)) :: BasePart
	if not primaryPart then return end

	local animator = humanoid:WaitForChild("Animator") :: Animator
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)

	-- Constraints
	local attachment = Instance.new("Attachment")
	attachment.Name  = "SwimAttachment"
	attachment.Parent = primaryPart

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name                  = "SwimVelocity"
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.RelativeTo            = Enum.ActuatorRelativeTo.World
	linearVelocity.Attachment0           = attachment
	linearVelocity.MaxForce              = 0
	linearVelocity.Parent                = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name              = "SwimOrientation"
	alignOrientation.Mode              = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0       = attachment
	alignOrientation.RigidityEnabled   = false
	alignOrientation.MaxTorque         = 100000
	alignOrientation.Responsiveness    = CFG.ALIGN_RESPONSIVENESS
	alignOrientation.Enabled           = false
	alignOrientation.Parent            = primaryPart

	-- Particle emitter (bubble trail)
	local bubbleEmitter = Instance.new("ParticleEmitter")
	bubbleEmitter.Texture           = "rbxassetid://243660364"
	bubbleEmitter.Size              = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.08),
		NumberSequenceKeypoint.new(0.5, 0.28),
		NumberSequenceKeypoint.new(1, 0.0),
	})
	bubbleEmitter.Transparency      = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	bubbleEmitter.LightInfluence    = 0.6
	bubbleEmitter.LightEmission     = 0.3
	bubbleEmitter.Color             = ColorSequence.new(Color3.fromRGB(180, 225, 255), Color3.fromRGB(255, 255, 255))
	bubbleEmitter.Lifetime          = NumberRange.new(0.7, 1.5)
	bubbleEmitter.Rate              = 0
	bubbleEmitter.Speed             = NumberRange.new(1.5, 4)
	bubbleEmitter.Rotation          = NumberRange.new(0, 360)
	bubbleEmitter.RotSpeed          = NumberRange.new(-90, 90)
	bubbleEmitter.SpreadAngle       = Vector2.new(30, 30)
	bubbleEmitter.EmissionDirection = Enum.NormalId.Top
	bubbleEmitter.Enabled           = true
	bubbleEmitter.Parent            = primaryPart

	-- Wake emitter (horizontal trail when moving)
	local wakeEmitter = Instance.new("ParticleEmitter")
	wakeEmitter.Texture           = "rbxassetid://243660364"
	wakeEmitter.Size              = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.0),
	})
	wakeEmitter.Transparency      = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	wakeEmitter.Color             = ColorSequence.new(Color3.fromRGB(200, 235, 255))
	wakeEmitter.Lifetime          = NumberRange.new(0.3, 0.6)
	wakeEmitter.Rate              = 0
	wakeEmitter.Speed             = NumberRange.new(0.5, 2)
	wakeEmitter.SpreadAngle       = Vector2.new(80, 80)
	wakeEmitter.EmissionDirection = Enum.NormalId.Back
	wakeEmitter.Enabled           = true
	wakeEmitter.Parent            = primaryPart

	-- Surface effects (swirl ring, foam, splash)
	local surfaceFx = makeSurfaceFx()

	-- Body hitbox: tagged "SwimHitbox", fitted to the pose you are swimming in, queryable only while swimming
	local hitbox = newEffectPart("SwimHitbox", Vector3.new(CFG.BODY_WIDTH, CFG.BODY_THICKNESS, 5))
	hitbox.Material     = Enum.Material.Neon
	hitbox.Color        = Color3.fromRGB(80, 200, 255)
	hitbox.Transparency = CFG.SHOW_HITBOX and 0.75 or 1
	hitbox:SetAttribute("OwnerUserId", LocalPlayer.UserId)
	hitbox:SetAttribute("Swimming", false)
	CollectionService:AddTag(hitbox, "SwimHitbox")
	hitbox.Parent = effectsFolder

	-- Post-processing
	local blurEffect = Instance.new("BlurEffect")
	blurEffect.Name    = "SwimBlur"
	blurEffect.Size    = 0
	blurEffect.Enabled = false

	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name       = "SwimColorCorrect"
	colorCorrection.TintColor  = Color3.fromRGB(255, 255, 255)
	colorCorrection.Brightness = 0
	colorCorrection.Contrast   = 0
	colorCorrection.Saturation = 0
	colorCorrection.Enabled    = false

	local savedFogEnd   = Lighting.FogEnd
	local savedFogColor = Lighting.FogColor

	-- Water detection
	local waterOverlapParams = OverlapParams.new()
	waterOverlapParams.FilterType = Enum.RaycastFilterType.Include

	local connections: { RBXScriptConnection } = {}
	local renderConnection: RBXScriptConnection?
	local visualConnection: RBXScriptConnection?

	local castParams = RaycastParams.new()
	castParams.IgnoreWater = true
	castParams.RespectCanCollide = true
	castParams.CollisionGroup = primaryPart.CollisionGroup

	local function RefreshWaterFilter()
		local tagged = CollectionService:GetTagged("Water")
		waterOverlapParams.FilterDescendantsInstances = tagged

		local ignore = table.clone(tagged)
		table.insert(ignore, character)
		table.insert(ignore, effectsFolder)
		castParams.ExcludeInstances = ignore
	end
	table.insert(connections, CollectionService:GetInstanceAddedSignal("Water"):Connect(RefreshWaterFilter))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal("Water"):Connect(RefreshWaterFilter))
	RefreshWaterFilter()

	local isUnderwater           = false
	local isRising               = false
	local isSinking              = false
	local currentTilt            = 0
	local wasUnderwaterLastFrame = false
	local currentVelocity        = Vector3.zero
	local isCleanedUp            = false
	local swimIdleAnim: AnimationTrack?
	local swimMoveAnim: AnimationTrack?
	local currentAnim: AnimationTrack?

	-- surface tracking
	local lastWaterTop: number? = nil
	local surfaceY: number? = nil
	local shownSurfaceY = 0
	local surfaceReady = false
	local surfaceTimer = 0
	local wakeTimer = 0
	local fxAlpha = 0
	local swirlTime = 0
	local movingNow = false
	local swirlPos = Vector3.zero
	local swirlReady = false
	local smoothLook = primaryPart.CFrame.LookVector
	local swimClock = 0
	local hitboxConnection: RBXScriptConnection?

	task.spawn(function()
		local animateScript = character:WaitForChild("Animate", 5)
		if isCleanedUp or humanoid.Health <= 0 then return end

		local idleObj = animateScript and (animateScript:FindFirstChild("SwimIdle", true) or animateScript:FindFirstChild("swimidle", true))
		local moveObj = animateScript and (animateScript:FindFirstChild("Swim", true) or animateScript:FindFirstChild("swim", true))

		local idleAnimInst = Instance.new("Animation")
		idleAnimInst.AnimationId = (idleObj and idleObj:IsA("Animation") and idleObj.AnimationId ~= "") and idleObj.AnimationId or CFG.FALLBACK_IDLE_ANIM

		local moveAnimInst = Instance.new("Animation")
		moveAnimInst.AnimationId = (moveObj and moveObj:IsA("Animation") and moveObj.AnimationId ~= "") and moveObj.AnimationId or CFG.FALLBACK_SWIM_ANIM

		local loadedIdle = animator:LoadAnimation(idleAnimInst)
		local loadedMove = animator:LoadAnimation(moveAnimInst)

		if isCleanedUp or humanoid.Health <= 0 then
			loadedIdle:Destroy()
			loadedMove:Destroy()
			return
		end

		loadedIdle.Priority = Enum.AnimationPriority.Action3
		loadedMove.Priority = Enum.AnimationPriority.Action3
		swimIdleAnim = loadedIdle
		swimMoveAnim = loadedMove
	end)

	local function CheckIsUnderwater(): boolean
		local pos     = primaryPart.Position
		local head    = pos + Vector3.new(0, 1.5, 0)
		local terrain = Workspace.Terrain

		if terrain:GetMaterialAtPosition(pos) == Enum.Material.Water then
			lastWaterTop = nil
			return true
		end
		if terrain:GetMaterialAtPosition(head) == Enum.Material.Water then
			lastWaterTop = nil
			return true
		end

		local cf    = CFrame.new(pos + Vector3.new(0, 0.75, 0))
		local sz    = Vector3.new(2, 3.5, 2)
		local parts = Workspace:GetPartBoundsInBox(cf, sz, waterOverlapParams)
		if #parts == 0 then
			lastWaterTop = nil
			return false
		end

		local top = -math.huge
		for _, part in parts do
			top = math.max(top, part.Position.Y + part.Size.Y * 0.5)
		end
		lastWaterTop = top
		return true
	end

	local function MeasureSurface(): number?
		local y = getSurfaceY(primaryPart, character, lastWaterTop)
		if y then
			surfaceY = y
			if not surfaceReady then
				surfaceReady = true
				shownSurfaceY = y
			end
		end
		return y
	end

	local function HandleAnimation(moving: boolean)
		local desired = moving and swimMoveAnim or swimIdleAnim
		if desired and desired ~= currentAnim then
			if currentAnim then currentAnim:Stop(0.2) end
			currentAnim = desired
			desired:Play(0.2)
		end
	end

	local function OnRiseAction(_, state: Enum.UserInputState)
		if isUnderwater then
			isRising = state == Enum.UserInputState.Begin
			return Enum.ContextActionResult.Sink
		end
		isRising = false
		return Enum.ContextActionResult.Pass
	end

	local function OnSinkAction(_, state: Enum.UserInputState)
		if isUnderwater then
			isSinking = state == Enum.UserInputState.Begin
			return Enum.ContextActionResult.Sink
		end
		isSinking = false
		return Enum.ContextActionResult.Pass
	end

	local function UnbindInputs()
		ContextActionService:UnbindAction(BIND_RISE)
		ContextActionService:UnbindAction(BIND_SINK)
		isRising  = false
		isSinking = false
	end

	local function BindInputs()
		UnbindInputs()
		ContextActionService:BindAction(BIND_RISE, OnRiseAction, false, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
		ContextActionService:BindAction(BIND_SINK, OnSinkAction, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonB)
	end

	local function ApplyUnderwaterFX(camera: Camera)
		blurEffect.Enabled        = true
		colorCorrection.Enabled   = true
		blurEffect.Parent         = camera
		colorCorrection.Parent    = camera
		TweenService:Create(blurEffect, TweenInfo.new(CFG.BLUR_TWEEN_TIME), { Size = CFG.BLUR_SIZE }):Play()
		TweenService:Create(colorCorrection, TweenInfo.new(CFG.BLUR_TWEEN_TIME), {
			TintColor  = CFG.UNDERWATER_FOG_COLOR,
			Brightness = -0.04,
			Saturation = -0.15,
		}):Play()
		TweenService:Create(Lighting, TweenInfo.new(CFG.BLUR_TWEEN_TIME), {
			FogEnd   = CFG.UNDERWATER_FOG_END,
			FogColor = CFG.UNDERWATER_FOG_COLOR,
		}):Play()
	end

	local function RemoveUnderwaterFX()
		TweenService:Create(blurEffect, TweenInfo.new(CFG.BLUR_TWEEN_TIME), { Size = 0 }):Play()
		TweenService:Create(colorCorrection, TweenInfo.new(CFG.BLUR_TWEEN_TIME), {
			TintColor  = Color3.fromRGB(255, 255, 255),
			Brightness = 0,
			Saturation = 0,
		}):Play()
		TweenService:Create(Lighting, TweenInfo.new(CFG.BLUR_TWEEN_TIME), {
			FogEnd   = savedFogEnd,
			FogColor = savedFogColor,
		}):Play()
		task.delay(CFG.BLUR_TWEEN_TIME + 0.05, function()
			blurEffect.Enabled      = false
			colorCorrection.Enabled = false
		end)
	end

	local function Cleanup()
		if isCleanedUp then return end
		isCleanedUp = true

		UnbindInputs()

		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
		if visualConnection then
			visualConnection:Disconnect()
			visualConnection = nil
		end
		if hitboxConnection then
			hitboxConnection:Disconnect()
			hitboxConnection = nil
		end

		for _, c in connections do c:Disconnect() end
		table.clear(connections)

		RemoveUnderwaterFX()

		humanoid.AutoRotate = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

		if currentAnim then currentAnim:Stop(0.1) end
		if swimIdleAnim then swimIdleAnim:Stop(0) swimIdleAnim:Destroy() end
		if swimMoveAnim then swimMoveAnim:Stop(0) swimMoveAnim:Destroy() end
		currentAnim  = nil
		swimIdleAnim = nil
		swimMoveAnim = nil

		linearVelocity:Destroy()
		alignOrientation:Destroy()
		bubbleEmitter:Destroy()
		wakeEmitter:Destroy()
		attachment:Destroy()
		surfaceFx.part:Destroy()
		hitbox:Destroy()

		task.delay(CFG.BLUR_TWEEN_TIME + 0.1, function()
			blurEffect:Destroy()
			colorCorrection:Destroy()
		end)
	end

	renderConnection = RunService.PreSimulation:Connect(function(deltaTime: number)
		if isCleanedUp or not character.Parent or humanoid.Health <= 0 then
			Cleanup()
			return
		end

		local camera = Workspace.CurrentCamera
		if not camera then return end

		isUnderwater = CheckIsUnderwater()

		if isUnderwater then
			if humanoid:GetStateEnabled(Enum.HumanoidStateType.Swimming) then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
			end

			if not wasUnderwaterLastFrame then
				wasUnderwaterLastFrame = true
				BindInputs()
				ApplyUnderwaterFX(camera)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

				smoothLook = primaryPart.CFrame.LookVector
				swimClock = 0
				local carried = primaryPart.AssemblyLinearVelocity
				if carried.Magnitude > CFG.ENTRY_MAX_SPEED then
					carried = carried.Unit * CFG.ENTRY_MAX_SPEED
				end
				currentVelocity = carried

				local entrySurface = MeasureSurface()
				surfaceTimer = 0.1
				if entrySurface and entrySurface - primaryPart.Position.Y < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position
					playSplash(surfaceFx, p.X, p.Z, entrySurface, true)
				end
			end

			-- re-read the surface height a few times per second
			surfaceTimer -= deltaTime
			if surfaceTimer <= 0 then
				surfaceTimer = 0.1
				MeasureSurface()
			end

			humanoid.AutoRotate    = false
			alignOrientation.Enabled = true
			linearVelocity.MaxForce  = 100000

			local moveDir = humanoid.MoveDirection
			local isMoving = moveDir.Magnitude > 0.05
			local targetVelocity = Vector3.zero

			if isMoving then
				local camCF      = camera.CFrame
				local rightVec   = camCF.RightVector
				local flatRight  = Vector3.new(rightVec.X, 0, rightVec.Z)

				if flatRight.Magnitude > 0.001 then
					local flatForward    = Vector3.yAxis:Cross(flatRight).Unit
					local yawCF          = CFrame.lookAt(Vector3.zero, flatForward)
					local localInput     = yawCF:VectorToObjectSpace(moveDir)
					local swimmingDir    = camCF:VectorToWorldSpace(localInput)
					if swimmingDir.Magnitude > 0.001 then
						targetVelocity = swimmingDir.Unit * CFG.SWIM_SPEED
					end
				end
			else
				targetVelocity = Vector3.new(0, -0.5, 0)
			end

			if isRising then
				targetVelocity = Vector3.new(targetVelocity.X, CFG.RISE_SPEED, targetVelocity.Z)
			elseif isSinking then
				targetVelocity = Vector3.new(targetVelocity.X, -CFG.SINK_SPEED, targetVelocity.Z)
			end

			-- Steering targets for this frame (input is sampled once per frame)
			local lookTarget = smoothLook
			local applyManualTilt = false
			if isMoving and targetVelocity.Magnitude > 0.1 then
				lookTarget = targetVelocity.Unit
			else
				local look = primaryPart.CFrame.LookVector
				local flatLook = Vector3.new(look.X, 0, look.Z)
				if flatLook.Magnitude > 0.001 then
					lookTarget = flatLook.Unit
				end
				applyManualTilt = true
			end

			-- Fixed 120 Hz swim tick: speed, turning and tilt always advance in identical steps, so they feel the
			-- same at 30, 60, 144 or 240 fps. (Scripts run once per rendered frame, so this cannot beat the frame rate.)
			swimClock += math.min(deltaTime, 0.25)
			local ticks = 0
			while swimClock >= SWIM_TICK and ticks < CFG.MAX_TICKS_PER_FRAME do
				swimClock -= SWIM_TICK
				ticks += 1

				currentVelocity = currentVelocity:Lerp(targetVelocity, TICK_VELOCITY_ALPHA)

				local normY = math.clamp(currentVelocity.Y / CFG.RISE_SPEED, -1, 1)
				local targetTilt = applyManualTilt and (-normY * CFG.TILT_MAX) or (-normY * CFG.TILT_MAX * 0.5)
				currentTilt = lerp(currentTilt, targetTilt, TICK_TILT_ALPHA)

				smoothLook = blendDirection(smoothLook, lookTarget, TICK_LOOK_ALPHA)
			end
			if ticks == CFG.MAX_TICKS_PER_FRAME then
				swimClock = 0 -- after a long hitch, drop the backlog instead of replaying it
			end

			-- Slide along walls instead of pushing into them: no sticking, and the posed limbs never clip in
			if currentVelocity.Magnitude > 0.05 then
				local bodyCF, bodySize = fitBody(character, primaryPart)
				currentVelocity = collideAndSlide(bodyCF, bodySize, currentVelocity, math.clamp(deltaTime, 1 / 240, 1 / 20), castParams)
			end
			linearVelocity.VectorVelocity = currentVelocity

			-- Particles
			local speed = currentVelocity.Magnitude
			bubbleEmitter.Rate = lerp(CFG.BUBBLE_RATE, CFG.BUBBLE_MOVE_RATE, math.clamp(speed / CFG.SWIM_SPEED, 0, 1))
			wakeEmitter.Rate   = isMoving and math.clamp(speed / CFG.SWIM_SPEED * 24, 0, 24) or 0

			-- Thin wake rings left behind on the surface while you swim near it
			movingNow = isMoving
			wakeTimer -= deltaTime
			local sy = surfaceY
			if isMoving and sy and wakeTimer <= 0 and (sy - primaryPart.Position.Y) < CFG.SURFACE_FX_DEPTH * 0.6 then
				wakeTimer = CFG.WAKE_RING_INTERVAL * lerp(1.5, 0.75, math.clamp(speed / CFG.SWIM_SPEED, 0, 1))
				local p = primaryPart.Position
				spawnRipple(p.X, p.Z, sy, CFG.WAKE_RING_DIAMETER, CFG.RIPPLE_TWEEN_TIME * 0.9)
			end

			-- Orientation (the look direction was smoothed in the swim tick above)
			local rightVec = camera.CFrame.RightVector
			local upVec    = rightVec:Cross(smoothLook)
			upVec          = upVec.Magnitude > 0.001 and upVec.Unit or Vector3.yAxis

			alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, smoothLook, upVec) * CFrame.Angles(math.rad(currentTilt), 0, 0)

			HandleAnimation(isMoving or isRising or isSinking)
		else
			if wasUnderwaterLastFrame then
				wasUnderwaterLastFrame = false

				local wasRising = isRising
				UnbindInputs()

				humanoid.AutoRotate      = true
				alignOrientation.Enabled = false
				bubbleEmitter.Rate       = 0
				wakeEmitter.Rate         = 0
				currentTilt              = 0

				linearVelocity.MaxForce       = 0
				linearVelocity.VectorVelocity = Vector3.zero
				currentVelocity               = Vector3.zero

				if currentAnim then currentAnim:Stop(0.2) end
				currentAnim = nil

				humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

				RemoveUnderwaterFX()

				local exitSurface = MeasureSurface() or surfaceY
				if exitSurface and math.abs(exitSurface - primaryPart.Position.Y) < CFG.ENTRY_MAX_DEPTH then
					local p = primaryPart.Position
					playSplash(surfaceFx, p.X, p.Z, exitSurface, false)
				end
				surfaceY     = nil
				surfaceReady = false
				movingNow    = false

				if wasRising then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					primaryPart.AssemblyLinearVelocity = Vector3.new(
						primaryPart.AssemblyLinearVelocity.X,
						CFG.RISE_SPEED,
						primaryPart.AssemblyLinearVelocity.Z
					)
				end
			end
		end
	end)

	-- Visual pass every rendered frame: the swirl ring + foam follow you smoothly.
	visualConnection = RunService.PreRender:Connect(function(deltaTime: number)
		if isCleanedUp then return end

		local sy = surfaceY
		local targetAlpha = 0
		if isUnderwater and sy then
			local depth = sy - primaryPart.Position.Y
			targetAlpha = 1 - math.clamp(
				(depth - CFG.SURFACE_FX_FULL_DEPTH) / (CFG.SURFACE_FX_DEPTH - CFG.SURFACE_FX_FULL_DEPTH),
				0, 1
			)
		end
		fxAlpha = lerp(fxAlpha, targetAlpha, expDecayAlpha(10, deltaTime))

		if not sy or fxAlpha < 0.01 then
			if surfaceFx.gui.Enabled then
				surfaceFx.gui.Enabled = false
			end
			surfaceFx.foam.Rate = 0
			swirlReady = false
			return
		end

		if not surfaceFx.gui.Enabled then
			surfaceFx.gui.Enabled = true
		end

		shownSurfaceY = lerp(shownSurfaceY, sy, expDecayAlpha(20, deltaTime))
		local pos = primaryPart.Position
		local target = Vector3.new(pos.X, shownSurfaceY + CFG.SURFACE_OFFSET, pos.Z)
		if swirlReady then
			swirlPos = swirlPos:Lerp(target, expDecayAlpha(CFG.SWIRL_FOLLOW_RATE, deltaTime))
		else
			swirlPos = target
			swirlReady = true
		end
		surfaceFx.part.CFrame = CFrame.new(swirlPos)

		-- swirl arcs orbit in opposite directions
		swirlTime += deltaTime
		local outerSpin = (swirlTime * CFG.SWIRL_SPEED) % 360
		local innerSpin = (-swirlTime * CFG.SWIRL_SPEED * 1.35) % 360
		surfaceFx.outer.coreGradient.Rotation = outerSpin
		surfaceFx.outer.haloGradient.Rotation = outerSpin
		surfaceFx.inner.coreGradient.Rotation = innerSpin
		surfaceFx.inner.haloGradient.Rotation = innerSpin

		local breathe = 0.6 + 0.035 * math.sin(swirlTime * 2.4)
		surfaceFx.inner.holder.Size = UDim2.fromScale(breathe, breathe)

		local a = fxAlpha
		surfaceFx.outer.core.Transparency = 1 - 0.65 * a
		surfaceFx.outer.halo.Transparency = 1 - 0.18 * a
		surfaceFx.inner.core.Transparency = 1 - 0.88 * a
		surfaceFx.inner.halo.Transparency = 1 - 0.26 * a

		local speedFactor = math.clamp(currentVelocity.Magnitude / CFG.SWIM_SPEED, 0, 1)
		surfaceFx.foam.Rate = movingNow and (CFG.FOAM_RATE * speedFactor * a) or 0
	end)

	-- Keep the hitbox on the posed body, after this frame's physics and animation have moved it.
	hitboxConnection = RunService.PostSimulation:Connect(function()
		if isCleanedUp then
			return
		end

		if isUnderwater then
			local boxCF, boxSize = fitBody(character, primaryPart)
			hitbox.CFrame = boxCF
			hitbox.Size = boxSize
			if not hitbox.CanQuery then
				hitbox.CanQuery = true
				hitbox:SetAttribute("Swimming", true)
			end
		elseif hitbox.CanQuery then
			hitbox.CanQuery = false
			hitbox:SetAttribute("Swimming", false)
		end
	end)

	table.insert(connections, humanoid.Died:Connect(Cleanup))
	table.insert(connections, character.AncestryChanged:Connect(function(_, parent)
		if not parent then Cleanup() end
	end))
end

if LocalPlayer.Character then
	task.spawn(SetupCharacter, LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(SetupCharacter)
