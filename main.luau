--!strict
--!optimize 2
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

local CFG = {
	SWIM_SPEED = 20,
	RISE_SPEED = 14,
	SINK_SPEED = 14,
	TILT_MAX = 35,
	TILT_RATE = 10,
	ALIGN_RESPONSIVENESS = 20,
	BLUR_SIZE = 6,
	LERP_HALFLIFE = 10,
	FALLBACK_IDLE_ANIM = "rbxassetid://913384386",
	FALLBACK_SWIM_ANIM = "rbxassetid://913389033",
}

local BIND_RISE = "CustomSwim_Rise"
local BIND_SINK = "CustomSwim_Sink"

local function SetupCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local primaryPart = (character.PrimaryPart or character:WaitForChild("HumanoidRootPart", 5)) :: BasePart
	if not primaryPart then return end

	local animator = humanoid:WaitForChild("Animator") :: Animator
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)

	local attachment = Instance.new("Attachment")
	attachment.Name = "SwimAttachment"
	attachment.Parent = primaryPart

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "SwimVelocity"
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = 0
	linearVelocity.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "SwimOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = 100000
	alignOrientation.Responsiveness = CFG.ALIGN_RESPONSIVENESS
	alignOrientation.Enabled = false
	alignOrientation.Parent = primaryPart

	local bubbleEmitter = Instance.new("ParticleEmitter")
	bubbleEmitter.Texture = "rbxassetid://243660364"
	bubbleEmitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 0.4)})
	bubbleEmitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1)})
	bubbleEmitter.Lifetime = NumberRange.new(0.8, 1.4)
	bubbleEmitter.Rate = 12
	bubbleEmitter.Speed = NumberRange.new(2, 4)
	bubbleEmitter.EmissionDirection = Enum.NormalId.Top
	bubbleEmitter.Enabled = false
	bubbleEmitter.Parent = primaryPart

	local blurEffect = Instance.new("BlurEffect")
	blurEffect.Name = "SwimBlur"
	blurEffect.Size = CFG.BLUR_SIZE
	blurEffect.Enabled = false

	local connections: { RBXScriptConnection } = {}
	local renderConnection: RBXScriptConnection?

	local waterOverlapParams = OverlapParams.new()
	waterOverlapParams.FilterType = Enum.RaycastFilterType.Include
	waterOverlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Water")

	local function RefreshWaterFilter()
		waterOverlapParams.FilterDescendantsInstances = CollectionService:GetTagged("Water")
	end

	table.insert(connections, CollectionService:GetInstanceAddedSignal("Water"):Connect(RefreshWaterFilter))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal("Water"):Connect(RefreshWaterFilter))
	RefreshWaterFilter()

	local isUnderwater = false
	local isRising = false
	local isSinking = false
	local currentTilt = 0
	local wasUnderwaterLastFrame = false
	local currentVelocity = Vector3.zero
	local isCleanedUp = false

	local swimIdleAnim: AnimationTrack?
	local swimMoveAnim: AnimationTrack?
	local currentAnim: AnimationTrack?

	task.spawn(function()
		local animateScript = character:WaitForChild("Animate", 5)
		if isCleanedUp or humanoid.Health <= 0 then return end

		local idleObj = animateScript and (animateScript:FindFirstChild("SwimIdle", true) or animateScript:FindFirstChild("swimidle", true))
		local moveObj = animateScript and (animateScript:FindFirstChild("Swim", true) or animateScript:FindFirstChild("swim", true))

		local idleAnimInstance: Animation
		if idleObj and idleObj:IsA("Animation") and idleObj.AnimationId ~= "" then
			idleAnimInstance = idleObj :: Animation
		else
			idleAnimInstance = Instance.new("Animation")
			idleAnimInstance.AnimationId = CFG.FALLBACK_IDLE_ANIM
		end

		local moveAnimInstance: Animation
		if moveObj and moveObj:IsA("Animation") and moveObj.AnimationId ~= "" then
			moveAnimInstance = moveObj :: Animation
		else
			moveAnimInstance = Instance.new("Animation")
			moveAnimInstance.AnimationId = CFG.FALLBACK_SWIM_ANIM
		end

		local loadedIdle = animator:LoadAnimation(idleAnimInstance)
		local loadedMove = animator:LoadAnimation(moveAnimInstance)

		if isCleanedUp or humanoid.Health <= 0 then
			loadedIdle:Destroy()
			loadedMove:Destroy()
			return
		end

		swimIdleAnim = loadedIdle
		swimIdleAnim.Priority = Enum.AnimationPriority.Action3

		swimMoveAnim = loadedMove
		swimMoveAnim.Priority = Enum.AnimationPriority.Action3
	end)

	local function CheckIsUnderwater(): boolean
		local rootPos = primaryPart.Position
		local headPos = rootPos + Vector3.new(0, 1.5, 0)

		if Workspace.Terrain:GetMaterialAtPosition(rootPos) == Enum.Material.Water or
		   Workspace.Terrain:GetMaterialAtPosition(headPos) == Enum.Material.Water then
			return true
		end

		local searchBoxCF = CFrame.new(rootPos + Vector3.new(0, 0.75, 0))
		local searchBoxSize = Vector3.new(2, 3.5, 2)
		local overlappingParts = Workspace:GetPartBoundsInBox(searchBoxCF, searchBoxSize, waterOverlapParams)

		return #overlappingParts > 0
	end

	local function HandleAnimation(moving: boolean)
		local desiredAnim = moving and swimMoveAnim or swimIdleAnim
		if currentAnim ~= desiredAnim then
			if currentAnim then currentAnim:Stop(0.2) end
			currentAnim = desiredAnim
			if currentAnim then currentAnim:Play(0.2) end
		end
	end

	local function OnRiseAction(_, state)
		if isUnderwater then
			isRising = (state == Enum.UserInputState.Begin)
			return Enum.ContextActionResult.Sink
		end
		isRising = false
		return Enum.ContextActionResult.Pass
	end

	local function OnSinkAction(_, state)
		if isUnderwater then
			isSinking = (state == Enum.UserInputState.Begin)
			return Enum.ContextActionResult.Sink
		end
		isSinking = false
		return Enum.ContextActionResult.Pass
	end

	local function UnbindInputs()
		ContextActionService:UnbindAction(BIND_RISE)
		ContextActionService:UnbindAction(BIND_SINK)
		isRising = false
		isSinking = false
	end

	local function BindInputs()
		UnbindInputs()
		ContextActionService:BindAction(BIND_RISE, OnRiseAction, false, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
		ContextActionService:BindAction(BIND_SINK, OnSinkAction, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonB)
	end

	local function Cleanup()
		if isCleanedUp then return end
		isCleanedUp = true

		UnbindInputs()

		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end

		for _, conn in connections do conn:Disconnect() end
		table.clear(connections)

		humanoid.AutoRotate = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

		if currentAnim then
			currentAnim:Stop(0.1)
			currentAnim = nil
		end
		if swimIdleAnim then
			swimIdleAnim:Stop(0)
			swimIdleAnim:Destroy()
			swimIdleAnim = nil
		end
		if swimMoveAnim then
			swimMoveAnim:Stop(0)
			swimMoveAnim:Destroy()
			swimMoveAnim = nil
		end

		linearVelocity:Destroy()
		alignOrientation:Destroy()
		bubbleEmitter:Destroy()
		attachment:Destroy()
		blurEffect:Destroy()
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
				BindInputs()
				wasUnderwaterLastFrame = true
				blurEffect.Parent = camera
				blurEffect.Enabled = true

				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
			end

			humanoid.AutoRotate = false
			alignOrientation.Enabled = true
			linearVelocity.MaxForce = 100000
			bubbleEmitter.Enabled = true

			local moveDir = humanoid.MoveDirection
			local isMoving = moveDir.Magnitude > 0.05
			local targetVelocity = Vector3.zero

			if isMoving then
				local camCF = camera.CFrame
				local rightVec = camCF.RightVector
				local flatRight = Vector3.new(rightVec.X, 0, rightVec.Z)

				if flatRight.Magnitude > 0.001 then
					local flatForward = Vector3.yAxis:Cross(flatRight).Unit
					local yawCF = CFrame.lookAt(Vector3.zero, flatForward)
					local localInput = yawCF:VectorToObjectSpace(moveDir)
					local swimmingDirection = camCF:VectorToWorldSpace(localInput)

					if swimmingDirection.Magnitude > 0.001 then
						targetVelocity = swimmingDirection.Unit * CFG.SWIM_SPEED
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

			local clampedDt = math.min(deltaTime, 0.1)
			local velocityAlpha = 1 - math.exp(-CFG.LERP_HALFLIFE * clampedDt)
			currentVelocity = currentVelocity:Lerp(targetVelocity, velocityAlpha)
			linearVelocity.VectorVelocity = currentVelocity

			local lookDir = primaryPart.CFrame.LookVector
			local applyManualTilt = false

			if isMoving and targetVelocity.Magnitude > 0.1 then
				lookDir = targetVelocity.Unit
			else
				local flatLook = Vector3.new(primaryPart.CFrame.LookVector.X, 0, primaryPart.CFrame.LookVector.Z)
				if flatLook.Magnitude > 0.001 then
					lookDir = flatLook.Unit
				end
				applyManualTilt = true
			end

			local normY = math.clamp(currentVelocity.Y / CFG.RISE_SPEED, -1, 1)
			local targetTilt = applyManualTilt and (-normY * CFG.TILT_MAX) or 0

			local tiltAlpha = 1 - math.exp(-CFG.TILT_RATE * clampedDt)
			currentTilt = currentTilt + (targetTilt - currentTilt) * tiltAlpha

			local rightVector = camera.CFrame.RightVector
			local upVector = rightVector:Cross(lookDir)

			if upVector.Magnitude < 0.001 then
				upVector = Vector3.yAxis
			else
				upVector = upVector.Unit
			end

			local baseCFrame = CFrame.lookAt(Vector3.zero, lookDir, upVector)
			if applyManualTilt then
				alignOrientation.CFrame = baseCFrame * CFrame.Angles(math.rad(currentTilt), 0, 0)
			else
				alignOrientation.CFrame = baseCFrame
			end

			HandleAnimation(isMoving or isRising or isSinking)
		else
			if wasUnderwaterLastFrame then
				wasUnderwaterLastFrame = false

				local wasRising = isRising

				UnbindInputs()

				humanoid.AutoRotate = true
				alignOrientation.Enabled = false
				bubbleEmitter.Enabled = false
				blurEffect.Enabled = false
				currentTilt = 0

				linearVelocity.MaxForce = 0
				linearVelocity.VectorVelocity = Vector3.zero
				currentVelocity = Vector3.zero

				if currentAnim then
					currentAnim:Stop(0.2)
					currentAnim = nil
				end

				humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

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
