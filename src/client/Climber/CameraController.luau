--!strict

-- Mouse-look head-cam and third-person toggle.
--
-- Revised after the phase 4 playtest. The camera used to take its orientation from
-- the climber's head, damped heavily, with no mouse-look at all -- the player could
-- not choose where to look. It did not survive contact with actual play, so the
-- mouse drives the view now and the focus-cam that existed to compensate is gone.
--
-- What survived, and why:
--
--   * Position still follows the Head part with light damping. This is the whole of
--     the remaining stabilisation and it is the half that was always doing the work:
--     the head bobs and jerks with the ragdoll, and the camera must not.
--   * The up vector is still hard-locked to world up. The view never rolls, ever.
--     Roll is not damped toward zero -- yaw and pitch are the only two numbers this
--     module keeps, so roll has nowhere to live. See NO_ROLL.
--
-- What did not survive: the head's *orientation* is now read nowhere. The camera
-- reads Head.Position and Head.Size and nothing else about it.
--
-- The two view modes take their input differently, and they aim differently as a
-- result. That split is deliberate, not an inconsistency:
--
--   First person  cursor locked to centre, all mouse movement turns the view, and
--                 the aim ray is the camera's own look direction. The reticle never
--                 moves within the viewport -- the player aims by turning.
--
--   Third person  Roblox's own camera. Free cursor, and the view turns only while
--                 the left button is held. Aiming is through the cursor, so the
--                 player points at a hold without reorienting the whole view.
--
-- The design doc's latency trick holds either way: both resolve locally and
-- instantly, and only the limb's pursuit of the target goes through the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Climber.Config)

local CameraController = {}

-- The hard up-lock, as a named constant so that a future edit has to delete
-- something called NO_ROLL rather than change an anonymous third argument.
local NO_ROLL = 0

-- The blend duration is a divisor. A zero left in Config would produce inf and then
-- nan, and a nan CFrame is an error that surfaces nowhere near its cause.
local MIN_BLEND = 1e-3

local MAX_PITCH = math.rad(Config.Camera.MaxPitch)
local TWO_PI = math.pi * 2

-- RIG ------------------------------------------------------------------------

local head: BasePart? = nil

local function resolveRig()
	local model = workspace:WaitForChild(Config.Rig.ModelName)
	head = model:WaitForChild("Head") :: BasePart
end

-- MATHS ----------------------------------------------------------------------

-- Exponential smoothing written so the result does not change with frame rate. A
-- plain `lerp(current, target, rate * dt)` would make the camera follow harder on a
-- 240Hz display than on a 60Hz one, which is a tuning trap: the feel settled on
-- would only be correct on the machine it was tuned on.
local function smoothAlpha(rate: number, deltaTime: number): number
	return 1 - math.exp(-rate * deltaTime)
end

-- Smoothstep, so the third-person toggle leaves and arrives at rest rather than
-- starting and stopping at full speed.
local function ease(t: number): number
	return t * t * (3 - 2 * t)
end

-- Moves a 0..1 blend parameter toward a target without overshooting it, so a very
-- long frame cannot push the toggle past its endpoint and back.
local function approach(current: number, target: number, step: number): number
	if current < target then
		return math.min(target, current + step)
	end
	return math.max(target, current - step)
end

-- STATE ----------------------------------------------------------------------

-- The damped follow of the head's position. The eye offset is applied afterwards,
-- in the camera's own frame, so the offset is rigidly attached to a view that never
-- rolls rather than to a head that does.
local stabilisedPosition = Config.Rig.SpawnPosition

-- False until the head has been seen once. The first frame snaps rather than damps,
-- because easing in from the bootstrap vantage would open every session with an
-- unrequested camera move.
local tracking = false

-- The view direction, and the only two numbers that describe it.
local yaw = 0
local pitch = 0

-- Mouse movement since the last frame. Accumulated from events rather than polled,
-- so movement that arrives between frames is added up rather than sampled and lost.
local pendingDelta = Vector2.zero

local thirdPersonAlpha = 0
local thirdPersonEnabled = false

-- Left button held. Only third person consults it: first person turns on every
-- mouse movement, held or not.
--
-- Tracked off the latch rather than the blend, so the cursor is freed the instant
-- the toggle is pressed rather than a third of a second later.
local rotating = false

-- The camera this module has already put into Scriptable mode. Re-read every frame
-- rather than captured once: if the engine ever swaps CurrentCamera out from under
-- us, a captured reference means writing CFrames to a camera nobody is looking
-- through, which looks like a frozen client and nothing else.
local configuredCamera: Camera? = nil

local function activeCamera(): Camera?
	local camera = workspace.CurrentCamera
	if camera and camera ~= configuredCamera then
		-- With CharacterAutoLoads off there is no character and so no default camera
		-- subject. Nothing else drives this camera; if this module stops writing to
		-- it, it stays exactly where it was left.
		camera.CameraType = Enum.CameraType.Scriptable
		configuredCamera = camera
	end
	return camera
end

-- VIEW -----------------------------------------------------------------------

-- Yaw and pitch become a rotation, and the third euler term is where the up vector
-- is locked to world up. Not damped toward zero -- zero.
local function rotation(): CFrame
	return CFrame.fromEulerAnglesYXZ(pitch, yaw, NO_ROLL)
end

-- Mirrors Roblox's default camera. The cursor is free until a drag starts and is
-- then pinned where it was pressed, so it cannot run off the edge of the screen
-- mid-rotation and reappear somewhere else on release.
local function updateMouseBehaviour()
	if not thirdPersonEnabled then
		UserInputService.MouseIconEnabled = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		return
	end

	UserInputService.MouseIconEnabled = true
	UserInputService.MouseBehavior = if rotating
		then Enum.MouseBehavior.LockCurrentPosition
		else Enum.MouseBehavior.Default
end

local function applyMouseDelta()
	local delta = pendingDelta
	pendingDelta = Vector2.zero

	-- Read and cleared above before this returns, so movement made while the view
	-- is not being turned is discarded rather than banked. Third person accumulates
	-- cursor travel the same way first person accumulates aim, and paying it out on
	-- the next click would snap the view by every pixel the cursor had crossed since
	-- the last drag.
	if thirdPersonEnabled and not rotating then
		return
	end

	-- Rightward mouse movement is positive X and has to turn the view right, which
	-- is *decreasing* yaw: a positive rotation about +Y swings the look vector from
	-- -Z toward -X, and -X is the viewer's left. Downward movement is positive Y and
	-- lowers the pitch, which is the uninverted convention.
	--
	-- Wrapped rather than left to grow. Yaw is otherwise unbounded, and a player who
	-- spins in one direction long enough would lose angular precision to the float.
	yaw = (yaw - delta.X * Config.Camera.MouseSensitivity) % TWO_PI

	-- Clamped short of vertical, where yaw stops being meaningful and the view can
	-- flip through the pole.
	pitch = math.clamp(pitch - delta.Y * Config.Camera.MouseSensitivity, -MAX_PITCH, MAX_PITCH)
end

local function updateStabilisedPosition(headPart: BasePart, deltaTime: number)
	if not tracking then
		tracking = true
		stabilisedPosition = headPart.Position
		return
	end

	stabilisedPosition = stabilisedPosition:Lerp(
		headPart.Position,
		smoothAlpha(Config.Camera.PositionFollowRate, deltaTime)
	)
end

local function updateThirdPersonAlpha(deltaTime: number)
	local target = if thirdPersonEnabled then 1 else 0
	thirdPersonAlpha = approach(
		thirdPersonAlpha,
		target,
		deltaTime / math.max(Config.Camera.ThirdPersonBlend, MIN_BLEND)
	)
end

-- Where the camera sits: at the eyes in first person, pulled back along the same
-- look direction in third. Both share one orientation, so the toggle moves the
-- camera without ever turning it.
local function eyeCFrame(headPart: BasePart): CFrame
	local rot = rotation()

	-- Measured from the head's front face rather than its centre, so the camera
	-- clears the head whatever proportions the modelled rig has. A fixed offset
	-- would sit inside a larger head and show the player its interior.
	local forward = headPart.Size.Z / 2 + Config.Camera.EyeClearance
	local eye = stabilisedPosition + rot * Vector3.new(0, Config.Camera.EyeHeight, -forward)

	local pulledBack = eye
		- rot.LookVector * Config.Camera.ThirdPersonDistance
		+ Vector3.yAxis * Config.Camera.ThirdPersonHeight

	return CFrame.new(eye:Lerp(pulledBack, ease(thirdPersonAlpha))) * rot
end

--------------------------------------------------------------------------------

-- Which view mode is live, and so which aiming model applies. TargetReticle asks
-- because the two aim differently: first person down the centre of a locked view,
-- third person through a free cursor.
--
-- Reports the latch rather than the blend, so aiming switches with the keypress
-- instead of drifting over during the third of a second the camera takes to move.
function CameraController.IsThirdPerson(): boolean
	return thirdPersonEnabled
end

function CameraController.Start()
	-- A vantage for the frames before the rig replicates, and the last thing in this
	-- module that reads SpawnPosition. Once the head is in hand the camera follows
	-- the live part and never consults Config for a position again.
	local bootstrapFocus = Config.Rig.SpawnPosition
	local bootstrapCFrame = CFrame.lookAt(bootstrapFocus + Config.Camera.BootstrapOffset, bootstrapFocus)

	-- Nothing in Start yields. Bootstrap.client.luau starts these modules in
	-- sequence, so a wait here would hold up the reticle, input and HUD behind the
	-- camera for no reason.
	task.spawn(resolveRig)

	-- Deliberately not filtered on gameProcessedEvent. Nothing else in this game
	-- consumes mouse movement, so the only thing that flag could do here is drop aim
	-- input. Whether the movement is *used* is decided in applyMouseDelta.
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			pendingDelta += Vector2.new(input.Delta.X, input.Delta.Y)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Dropped, not kept. Movement can land between the last frame and this
			-- press, and applying it on the first frame of the drag would kick the
			-- view by however far the cursor travelled on its way to the click.
			pendingDelta = Vector2.zero
			rotating = true
			return
		end

		if input.KeyCode == Config.Camera.ToggleKey then
			-- A setting, not a hold: this latches until pressed again.
			thirdPersonEnabled = not thirdPersonEnabled
		end
	end)

	-- Not filtered on gameProcessedEvent, unlike the press. A drag that begins on
	-- open screen and ends over a GUI element still has to end, or the camera stays
	-- stuck in rotate mode with the button already released.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			rotating = false
		end
	end)

	-- Camera priority runs after input is gathered and before the frame is drawn,
	-- which is where a camera update belongs. TargetReticle binds one priority later
	-- so that its aim ray reads this frame's camera rather than last frame's.
	RunService:BindToRenderStep("ClimberCamera", Enum.RenderPriority.Camera.Value, function(deltaTime: number)
		local camera = activeCamera()
		if not camera then
			return
		end

		-- Re-asserted every frame rather than set once. The engine releases the lock
		-- on focus loss, and a camera that stops turning after an alt-tab reads as a
		-- frozen client rather than as a released mouse.
		updateMouseBehaviour()

		applyMouseDelta()
		updateThirdPersonAlpha(deltaTime)

		local headPart = head
		if not headPart then
			camera.CFrame = bootstrapCFrame
			return
		end

		updateStabilisedPosition(headPart, deltaTime)
		camera.CFrame = eyeCFrame(headPart)
	end)
end

return CameraController
