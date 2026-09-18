--!strict
--!optimize 2
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer

local CFG = {
	SWIM_SPEED            = 22,
	RISE_SPEED            = 16,
	SINK_SPEED            = 16,
	TILT_MAX              = 38,
	TILT_RATE             = 12,
	ALIGN_RESPONSIVENESS  = 25,
	VELOCITY_HALFLIFE     = 12,
	BLUR_SIZE             = 8,
	BLUR_TWEEN_TIME       = 0.35,
	UNDERWATER_FOG_END    = 80,
	UNDERWATER_FOG_COLOR  = Color3.fromRGB(30, 90, 160),
	BUBBLE_RATE           = 18,
	BUBBLE_MOVE_RATE      = 36,
	SPLASH_COUNT          = 16,
	RIPPLE_TWEEN_TIME     = 0.65,
	FALLBACK_IDLE_ANIM    = "rbxassetid://913384386",
	FALLBACK_SWIM_ANIM    = "rbxassetid://913389033",
}

local BIND_RISE = "CustomSwim_Rise"
local BIND_SINK = "CustomSwim_Sink"

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function expDecayAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * math.min(dt, 0.1))
end

local function spawnSplash(root: BasePart, surfaceY: number)
	for i = 1, CFG.SPLASH_COUNT do
		local p = Instance.new("Part")
		p.Shape        = Enum.PartType.Ball
		p.Size         = Vector3.one * (0.15 + math.random() * 0.25)
		p.Material     = Enum.Material.SmoothPlastic
		p.Color        = Color3.fromRGB(170, 215, 255)
		p.Transparency = 0.2
		p.CanCollide   = false
		p.Anchored     = false
		p.Massless     = true
		p.CastShadow   = false
		p.CFrame       = CFrame.new(root.Position.X, surfaceY, root.Position.Z)
		p.Parent       = Workspace

		local angle  = (i / CFG.SPLASH_COUNT) * math.pi * 2
		local spd    = 5 + math.random() * 9
		local bv     = Instance.new("BodyVelocity")
		bv.Velocity  = Vector3.new(math.cos(angle) * spd, math.random() * 16 + 5, math.sin(angle) * spd)
		bv.MaxForce  = Vector3.new(math.huge, math.huge, math.huge)
		bv.P         = 1400
		bv.Parent    = p

		local life = 0.5 + math.random() * 0.4
		TweenService:Create(p, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
			Size         = Vector3.zero,
		}):Play()
		game:GetService("Debris"):AddItem(p, life + 0.05)
	end
end

local function spawnRipple(root: BasePart, surfaceY: number)
	local ring = Instance.new("Part")
	ring.Size         = Vector3.new(0.8, 0.04, 0.8)
	ring.Shape        = Enum.PartType.Cylinder
	ring.Material     = Enum.Material.Neon
	ring.Color        = Color3.fromRGB(100, 190, 255)
	ring.Transparency = 0.25
	ring.CanCollide   = false
	ring.Anchored     = true
	ring.CastShadow   = false
	ring.CFrame       = CFrame.new(root.Position.X, surfaceY, root.Position.Z) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent       = Workspace

	TweenService:Create(ring, TweenInfo.new(CFG.RIPPLE_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = Vector3.new(0.04, root.Size.X * 5, root.Size.X * 5),
		Transparency = 1,
	}):Play()
	game:GetService("Debris"):AddItem(ring, CFG.RIPPLE_TWEEN_TIME + 0.05)
end

local function getSurfaceY(root: BasePart, character: Model): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = false
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, 80, 0), params)
	return (hit and hit.Material == Enum.Material.Water) and hit.Position.Y or root.Position.Y + 4
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

	local function RefreshWaterFilter()
		waterOverlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Water")
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
		local pos  = primaryPart.Position
		local head = pos + Vector3.new(0, 1.5, 0)
		if Workspace.Terrain:GetMaterialAtPosition(pos)  == Enum.Material.Water then return true end
		if Workspace.Terrain:GetMaterialAtPosition(head) == Enum.Material.Water then return true end
		local cf   = CFrame.new(pos + Vector3.new(0, 0.75, 0))
		local sz   = Vector3.new(2, 3.5, 2)
		return #Workspace:GetPartBoundsInBox(cf, sz, waterOverlapParams) > 0
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

				local surfY = getSurfaceY(primaryPart, character)
				spawnSplash(primaryPart, surfY)
				spawnRipple(primaryPart, surfY)
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

			currentVelocity        = currentVelocity:Lerp(targetVelocity, expDecayAlpha(CFG.VELOCITY_HALFLIFE, deltaTime))
			linearVelocity.VectorVelocity = currentVelocity

			-- Particles
			local speed = currentVelocity.Magnitude
			bubbleEmitter.Rate = lerp(CFG.BUBBLE_RATE, CFG.BUBBLE_MOVE_RATE, math.clamp(speed / CFG.SWIM_SPEED, 0, 1))
			wakeEmitter.Rate   = isMoving and math.clamp(speed / CFG.SWIM_SPEED * 24, 0, 24) or 0

			-- Orientation
			local lookDir = primaryPart.CFrame.LookVector
			local applyManualTilt = false

			if isMoving and targetVelocity.Magnitude > 0.1 then
				lookDir = targetVelocity.Unit
			else
				local flatLook = Vector3.new(primaryPart.CFrame.LookVector.X, 0, primaryPart.CFrame.LookVector.Z)
				if flatLook.Magnitude > 0.001 then lookDir = flatLook.Unit end
				applyManualTilt = true
			end

			local normY     = math.clamp(currentVelocity.Y / CFG.RISE_SPEED, -1, 1)
			local targetTilt = applyManualTilt and (-normY * CFG.TILT_MAX) or (-normY * CFG.TILT_MAX * 0.5)
			currentTilt     = lerp(currentTilt, targetTilt, expDecayAlpha(CFG.TILT_RATE, deltaTime))

			local rightVec = camera.CFrame.RightVector
			local upVec    = rightVec:Cross(lookDir)
			upVec          = upVec.Magnitude > 0.001 and upVec.Unit or Vector3.yAxis

			alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, lookDir, upVec) * CFrame.Angles(math.rad(currentTilt), 0, 0)

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

				local surfY = getSurfaceY(primaryPart, character)
				spawnRipple(primaryPart, surfY)

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

	table.insert(connections, humanoid.Died:Connect(Cleanup))
	table.insert(connections, character.AncestryChanged:Connect(function(_, parent)
		if not parent then Cleanup() end
	end))
end

if LocalPlayer.Character then
	task.spawn(SetupCharacter, LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(SetupCharacter)
