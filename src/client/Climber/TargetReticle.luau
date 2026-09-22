--!strict

-- The local, instant aim point.
--
-- This is the latency trick from the design doc: the limb's pursuit of the target
-- goes through the server and lags, but the aim is resolved locally every frame and
-- never does.
--
-- How the aim is resolved follows the camera mode, because the two modes put the
-- cursor in different places:
--
--   First person  the cursor is locked to the centre, so the aim ray is the
--                 camera's own look direction and this dot is the reticle.
--
--   Third person  the cursor is free and is itself the aim point, so the ray is
--                 cast through it and this dot is hidden rather than drawn on top
--                 of a cursor that already marks the spot.
--
-- Either way it resolves locally every frame and never waits on the server.
--
-- Nothing in here may wait on, or be corrected by, anything from the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Climber.Config)

local CameraController = require(script.Parent.CameraController)

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
	-- The first-person resting place. IgnoreGuiInset above makes GUI space match
	-- viewport space, so this lands on the camera's optical centre -- exactly where
	-- the first-person aim ray is cast.
	dot.Position = UDim2.fromScale(0.5, 0.5)
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

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- Waits for the rig model only, never for a part inside it, and off the main
	-- path so the dot draws from the first frame. FilterDescendantsInstances is
	-- evaluated per cast, so rig parts are excluded as they arrive without this
	-- having to wait for any of them.
	task.spawn(function()
		local rig = workspace:WaitForChild(Config.Rig.ModelName)
		params.FilterDescendantsInstances = { rig }
	end)

	-- The torso is still anchored at SpawnPosition, so the clamp origin is known
	-- without replication. This has to read the live torso once the torso can move,
	-- which is phase 5. (CameraController used to share this workaround for the
	-- camera position; phase 4 removed it there -- the head-cam reads the live Head.)
	local origin = Config.Rig.SpawnPosition

	-- Bound one priority after CameraController rather than on RenderStepped, which
	-- runs before it. On RenderStepped this would aim down last frame's camera, and
	-- with mouse-look that is a frame of aim lag in the one system whose entire job
	-- is to have none.
	RunService:BindToRenderStep("ClimberReticle", Enum.RenderPriority.Camera.Value + 1, function()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		local eye: Vector3
		local direction: Vector3

		if CameraController.IsThirdPerson() then
			-- The visible cursor is the aim point, so the ray goes through it and
			-- the dot stays hidden rather than sitting on top of a cursor that
			-- already marks the spot. GetMouseLocation pairs with ViewportPointToRay
			-- by definition, which is why the cursor path uses it and the centre
			-- path does not need to.
			dot.Visible = false

			local cursor = UserInputService:GetMouseLocation()
			local ray = camera:ViewportPointToRay(cursor.X, cursor.Y)
			eye = ray.Origin
			direction = ray.Direction
		else
			-- Straight off the camera rather than through ViewportPointToRay at the
			-- centre pixel: the look vector *is* the optical centre, with no viewport
			-- rounding or GUI inset in between.
			dot.Visible = true

			eye = camera.CFrame.Position
			direction = camera.CFrame.LookVector
		end

		local reach = Config.Grip.MaxTargetDistance * 2
		local hit = workspace:Raycast(eye, direction * reach, params)

		local aim = if hit then hit.Position else eye + direction * reach
		targetPosition = clampToReach(aim, origin)
	end)
end

return TargetReticle
