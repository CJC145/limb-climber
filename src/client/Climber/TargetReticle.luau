--!strict

-- The local, instant aim point.
--
-- This is the latency trick from the design doc: the limb's pursuit of the target
-- goes through the server and lags, but the reticle is drawn locally at the mouse
-- every frame and never does. Players read responsiveness from the cursor.
--
-- Nothing in here may wait on, or be corrected by, anything from the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Climber.Config)

local TargetReticle = {}

local targetPosition = Vector3.zero

local function createGui(): Frame
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Reticle"
	screenGui.ResetOnSpawn = false
	-- Matches GUI space to viewport space, so the dot lands exactly where the
	-- aim ray is cast from.
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.Size = UDim2.fromOffset(8, 8)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = Color3.new(1, 1, 1)
	dot.BorderSizePixel = 0
	dot.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	return dot
end

-- Mirrors the server's clamp so the drawn target never promises reach the limb
-- does not have.
local function clampToReach(target: Vector3, origin: Vector3): Vector3
	local offset = target - origin
	local distance = offset.Magnitude

	if distance <= Config.Grip.MaxTargetDistance or distance == 0 then
		return target
	end

	return origin + offset.Unit * Config.Grip.MaxTargetDistance
end

function TargetReticle.GetTargetPosition(): Vector3
	return targetPosition
end

function TargetReticle.Start()
	local dot = createGui()

	local rig = workspace:WaitForChild(Config.Rig.ModelName) :: Model
	local torso = rig:WaitForChild("Torso") :: BasePart

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig }

	RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		local mouse = UserInputService:GetMouseLocation()
		dot.Position = UDim2.fromOffset(mouse.X, mouse.Y)

		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local reach = Config.Grip.MaxTargetDistance * 2
		local hit = workspace:Raycast(ray.Origin, ray.Direction * reach, params)

		local aim = if hit then hit.Position else ray.Origin + ray.Direction * reach
		targetPosition = clampToReach(aim, torso.Position)
	end)
end

return TargetReticle
