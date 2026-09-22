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
local aimOrigin = Vector3.zero

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

-- The aim point, unclamped.
--
-- This used to mirror the server's reach clamp, back when that clamp was one radius
-- around the torso and could therefore be mirrored. It is now a separate envelope
-- per limb, measured around a shoulder or a hip, and one reticle cannot stand for
-- four of them.
--
-- Nothing is lost by dropping it. The clamp never reached the screen in either view
-- mode -- the first-person dot is pinned to the centre of the viewport and the
-- third-person dot is hidden behind the cursor -- so its only effect was on the
-- value sent, and the server clamps that authoritatively anyway. Mirroring it here
-- would have been a second copy of the rig's proportions living on the client, and
-- the point of aiming past a hold is that the limb stretches toward it, which is
-- what the server's clamp already does.
function TargetReticle.GetTargetPosition(): Vector3
	return targetPosition
end

-- Where this frame's aim ray was cast from: the camera's own position in first
-- person, and the point the cursor ray leaves the viewport in third.
--
-- Sent alongside the target so the server can clamp along the ray rather than
-- radially. The eye is the only part of the aim the server cannot work out for
-- itself -- it knows where the body is, but not where the player is looking from.
function TargetReticle.GetAimOrigin(): Vector3
	return aimOrigin
end

function TargetReticle.Start()
	local dot = createGui()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- Waits for the rig model only, never for a part inside it, and off the main path
	-- so the dot draws from the first frame. FilterDescendantsInstances is evaluated
	-- per cast, so rig parts are excluded as they arrive without this having to wait
	-- for any of them.
	--
	-- Nothing else here reads the rig. The aim is a ray from the camera into the
	-- world, and with the clamp gone this module no longer needs to know where the
	-- body is at all -- which is the right shape for the one system whose entire job
	-- is to resolve without waiting for anything.
	task.spawn(function()
		params.FilterDescendantsInstances = { workspace:WaitForChild(Config.Rig.ModelName) }
	end)

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

		-- The full aim range, not double it. The doubling used to exist so the ray
		-- could find a surface beyond the clamp and still give the clamp a direction
		-- to keep; with no clamp here, MaxTargetDistance is simply how far a player
		-- may point and the ray is exactly that long.
		local reach = Config.Grip.MaxTargetDistance
		local hit = workspace:Raycast(eye, direction * reach, params)

		-- Both published together, from the same cast. The pair has to describe one
		-- ray: an origin from this frame and a target from the last would define a
		-- line through neither.
		aimOrigin = eye
		targetPosition = if hit then hit.Position else eye + direction * reach
	end)
end

return TargetReticle
