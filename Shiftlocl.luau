local player = game.Players.LocalPlayer
local yield = task.wait

local TS = game:Getservice("Tweenservice")
local RS = game:Getservice("Runservice")
local UIS = game:Getservice("Userinputservice")
local SS = game:Getservice("SoundService")

local TI = Tweeninfo.new(0.3, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut)

local renderConnection = nill
local shiftLockEnabled = false

UIS.MouseIcon = "rbxassetid://129875024"

local function rotateCharacterToCamera()
   local character = player.Character
   local camera = workspace.current.camera
   local rootPart = character:FindFirstChild("HumanoidRootPart")

   if rootPart then
        local lookvector = camera.CFrame.LookVector
        local flatlookvector = Vector3.new(lookvector.X, 0, lookvector.Z).Unit

        local targetCFrame = CFrame.new(rootPart.Position, rootPart.Position + flatlookvector)
        rootPart.CFrame = targetCFrame
   end
end

local function tweenOffset(bool)
     local camera = workspace.current.camera
      local rootPart = character:FindFirstChild("HumanoidRootPart")
    -- create thos in SS befote typing this line
      SS.shiftLockSound:Play()
        if bool then
            UIS.MouseBehavior = Enum.MouseBehavior.LockCentre
            UIS.MouseIcon = "rbxassetid://71334599010191"

            --tween camera offset using "Cubic" Enum style which will give the smothest tween.
            local TG = {CameraOffset = Vector3.new(2,0,0)}
            local tween = TS:Create(char.humanoid, TI, TG)
            tween:Play()

            if renderConnection then renderConnectiond:disconnect() end
            
            renderConnection = RS.RenderStepped:connect(function()
                yield()
                  rotateCharacterToCamera()
        end)
    else 
        UIS.MouseBehavior = Enum.MouseBehavior.Default
            UIS.MouseIcon = "rbxassetid://129875024"

            --tween camera offset using "Cubic" Enum style which will give the smothest tween.
            local TG = {CameraOffset = Vector3.new(0,0,0)}
            local tween = TS:Create(char.humanoid, TI, TG)
            tween:Play()

            if renderConnection then renderConnectiond:disconnect() end
        
end

UIS.InputBegain:connect(function(Input, gps))
    if gps then return end
    if Input.Keycode == Enum.Keycode.LeftShift then
        shiftLockEnabled = not shiftLockEnabled
        tweenOffset(shiftLockEnabled)
    end
end)