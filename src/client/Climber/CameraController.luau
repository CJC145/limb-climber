--!strict

-- Stabilised head-cam, focus-cam blending, third-person toggle.
--
-- Three rules from the design doc drive everything here, and the last two are what
-- separate a camera on a ragdoll from a motion-sickness generator:
--
--   1. Follow the head's position with light damping.
--   2. Damp rotation heavily. Never copy the head's orientation directly.
--   3. Hard-lock the up vector to world up. The view never rolls, ever.
--
-- Rule 3 is why this module works in (position, yaw, pitch) instead of CFrames.
-- Two roll-free CFrames slerped together are *not* roll-free in between, so
-- blending poses as CFrames would let roll back in for the duration of every focus
-- blend -- precisely when the camera is moving most and the player is most likely
-- to feel it. Reducing a pose to three numbers and rebuilding it with a literal
-- zero roll term makes roll unrepresentable rather than merely small.
--
-- There is no mouse-look. The camera turns when the climber's head turns and at no
-- other time, and the reticle is a free cursor over a view the player does not
-- steer. That helplessness is the intended feel, not an omission.
--
-- Every player runs their own copy, spectators included. Per the design doc the
-- resulting asymmetry -- four screens showing four different parts of the climb --
-- is a feature, because it forces players to describe what they can see.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Climber.Config)
local Types = require(ReplicatedStorage.Climber.Types)

local InputRouter = require(script.Parent.InputRouter)

type LimbId = Types.LimbId

-- A camera pose, reduced to what survives the up-lock. Anything a CFrame can say
-- that these three cannot is roll, which is the point.
type Pose = {
	position: Vector3,
	yaw: number,
	pitch: number,
}

local CameraController = {}

local TWO_PI = math.pi * 2
local MAX_PITCH = math.rad(Config.Camera.MaxPitch)

-- The hard lock, as a named constant so that a future edit to the rebuild below has
-- to delete something called NO_ROLL rather than change an anonymous third argument.
local NO_ROLL = 0

-- Blend durations are divisors. A zero left in Config would produce inf and then
-- nan, and a nan CFrame is an error that surfaces nowhere near its cause.
local MIN_BLEND = 1e-3

-- RIG ------------------------------------------------------------------------
--
-- Read-only, and for framing only. The client never writes rig state -- it is
-- looking at replicated positions to decide where to stand, which is display, not
-- authority.

local head: BasePart? = nil
local torso: BasePart? = nil
local extremities: { [LimbId]: BasePart } = {}

local function resolveRig()
	local model = workspace:WaitForChild(Config.Rig.ModelName)

	local resolvedTorso = model:WaitForChild("Torso") :: BasePart
	for limbId, partName in Config.Rig.Extremity do
		extremities[limbId] = model:WaitForChild(partName) :: BasePart
	end

	torso = resolvedTorso

	-- Assigned last on purpose: the render loop tests `head` alone to decide whether
	-- the rig is usable, which is only true if everything else is already in place.
	head = model:WaitForChild("Head") :: BasePart
end

-- MATHS ----------------------------------------------------------------------

-- Shortest arc between two angles, so damping across the +/-pi seam takes the short
-- way round. Without this a head that turns past the seam sends the camera sweeping
-- the long way through a full rotation.
local function angleDelta(from: number, to: number): number
	return (to - from + math.pi) % TWO_PI - math.pi
end

local function lerpAngle(from: number, to: number, alpha: number): number
	return from + angleDelta(from, to) * alpha
end

-- Exponential smoothing written so the result does not change with frame rate. A
-- plain `lerp(current, target, rate * dt)` would make the camera follow harder on a
-- 240Hz display than on a 60Hz one, which is a tuning trap: the feel you settle on
-- would only be correct on the machine you tuned it on.
local function smoothAlpha(rate: number, deltaTime: number): number
	return 1 - math.exp(-rate * deltaTime)
end

-- Smoothstep. The focus blend uses it so the camera leaves and arrives at rest
-- rather than starting and stopping at full speed, which reads as a jolt at both
-- ends of a move this large.
local function ease(t: number): number
	return t * t * (3 - 2 * t)
end

-- A direction becomes yaw and pitch; roll has nowhere to go. The fallback covers a
-- zero-length direction, where the angles are genuinely undefined and holding the
-- previous frame's is the only answer that does not snap the view.
local function anglesFromDirection(direction: Vector3, fallbackYaw: number, fallbackPitch: number): (number, number)
	if direction.Magnitude < 1e-4 then
		return fallbackYaw, fallbackPitch
	end

	local unit = direction.Unit
	local yaw = math.atan2(-unit.X, -unit.Z)
	local pitch = math.clamp(math.asin(math.clamp(unit.Y, -1, 1)), -MAX_PITCH, MAX_PITCH)

	return yaw, pitch
end

-- Yaw and pitch become a rotation, and the third euler term is where the up vector
-- is locked to world up. Not damped toward zero -- zero.
local function rotationOf(pose: Pose): CFrame
	return CFrame.fromEulerAnglesYXZ(pose.pitch, pose.yaw, NO_ROLL)
end

local function poseToCFrame(pose: Pose): CFrame
	return CFrame.new(pose.position) * rotationOf(pose)
end

local function blendPoses(from: Pose, to: Pose, alpha: number): Pose
	return {
		position = from.position:Lerp(to.position, alpha),
		yaw = lerpAngle(from.yaw, to.yaw, alpha),
		pitch = from.pitch + (to.pitch - from.pitch) * alpha,
	}
end

-- Moves a 0..1 blend parameter toward a target without overshooting it, so a very
-- long frame cannot push a blend past its endpoint and back.
local function approach(current: number, target: number, step: number): number
	if current < target then
		return math.min(target, current + step)
	end
	return math.max(target, current - step)
end

-- STATE ----------------------------------------------------------------------

-- The damped follow of the head. Position tracks the head part itself; the eye
-- offset is applied afterwards, in the stabilised frame, so that a rolling head
-- cannot swing the eye point sideways even though it is offset from the head's
-- centre.
local stabilised: Pose = {
	position = Config.Rig.SpawnPosition,
	yaw = 0,
	pitch = 0,
}

-- False until the head has been seen once. The first frame snaps rather than damps,
-- because damping in from the bootstrap vantage would open every session with an
-- unrequested camera move.
local tracking = false

local focusAlpha = 0
local thirdPersonAlpha = 0
local thirdPersonEnabled = false

-- Held across the blend out. The player has let go by then, so InputRouter is
-- already reporting nil, but the pose still has to be computable until the blend
-- finishes or the camera would cut rather than return.
local focusLimb: LimbId? = nil

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

-- POSES ----------------------------------------------------------------------

-- Where the camera sits when nothing is being focused: at the eyes in first person,
-- pulled back along the same stabilised look direction in third. Both share one
-- orientation, so the toggle moves the camera without ever turning it.
local function restPose(headPart: BasePart): Pose
	local rotation = rotationOf(stabilised)

	-- Measured from the head's front face rather than its centre, so the camera
	-- clears the head whatever proportions the modelled rig has. A fixed offset
	-- would sit inside a larger head and show the player its interior.
	local forward = headPart.Size.Z / 2 + Config.Camera.EyeClearance
	local eye = stabilised.position + rotation * Vector3.new(0, Config.Camera.EyeHeight, -forward)

	local pulledBack = eye
		- rotation.LookVector * Config.Camera.ThirdPersonDistance
		+ Vector3.yAxis * Config.Camera.ThirdPersonHeight

	return {
		position = eye:Lerp(pulledBack, ease(thirdPersonAlpha)),
		yaw = stabilised.yaw,
		pitch = stabilised.pitch,
	}
end

-- Not mounted on the limb. The design doc rules that out explicitly, and a camera
-- bolted to a swinging arm is unusable regardless. This finds a vantage that frames
-- the limb and the space it is reaching into, from behind and to that limb's side,
-- so the limb sits in the foreground and its target area beyond it.
local function focusPose(limbId: LimbId, rest: Pose): Pose
	local extremity = extremities[limbId]
	local bodyPart = torso
	if not extremity or not bodyPart then
		return rest
	end

	-- Centred between body and limb rather than on the extremity, per FocusBias:
	-- centring on the extremity alone would track a moving part and reintroduce
	-- exactly the motion the head-cam damping exists to remove.
	local focusPoint = bodyPart.Position:Lerp(extremity.Position, Config.Camera.FocusBias)

	-- Built from the stabilised orientation rather than the raw head, so the
	-- vantage inherits the damping instead of needing its own.
	local rotation = rotationOf(rest)

	-- RightVector is horizontal for any roll-free rotation, so the step toward the
	-- limb's shoulder never tilts the vantage out of the plane it should be in.
	local side = if Config.Rig.Side[limbId] == "Right" then 1 else -1

	local vantage = focusPoint
		- rotation.LookVector * Config.Camera.FocusDistance
		+ rotation.RightVector * (side * Config.Camera.FocusShoulderOffset)
		+ Vector3.yAxis * Config.Camera.FocusHeight

	local yaw, pitch = anglesFromDirection(focusPoint - vantage, rest.yaw, rest.pitch)

	return { position = vantage, yaw = yaw, pitch = pitch }
end

-- FRAME ----------------------------------------------------------------------

local function updateStabilised(headPart: BasePart, deltaTime: number)
	local targetYaw, targetPitch = anglesFromDirection(
		headPart.CFrame.LookVector,
		stabilised.yaw,
		stabilised.pitch
	)

	if not tracking then
		tracking = true
		stabilised = { position = headPart.Position, yaw = targetYaw, pitch = targetPitch }
		return
	end

	-- Two rates, and the distance between them is the entire effect: the camera
	-- keeps up with where the head *is* while lagging badly behind where it is
	-- looking. The body flails; the horizon does not.
	local positionAlpha = smoothAlpha(Config.Camera.PositionFollowRate, deltaTime)
	local rotationAlpha = smoothAlpha(Config.Camera.RotationFollowRate, deltaTime)

	stabilised = {
		position = stabilised.position:Lerp(headPart.Position, positionAlpha),
		yaw = lerpAngle(stabilised.yaw, targetYaw, rotationAlpha),
		pitch = stabilised.pitch + (targetPitch - stabilised.pitch) * rotationAlpha,
	}
end

local function updateFocusAlpha(deltaTime: number)
	local requested = InputRouter.GetFocusLimb()

	if requested then
		-- Re-targets live. A player holding two keys is framed on the one they
		-- reached for most recently, and pressing a second key part-way through a
		-- blend redirects it rather than queueing behind it.
		focusLimb = requested
		focusAlpha = approach(focusAlpha, 1, deltaTime / math.max(Config.Camera.FocusBlendIn, MIN_BLEND))
		return
	end

	focusAlpha = approach(focusAlpha, 0, deltaTime / math.max(Config.Camera.FocusBlendOut, MIN_BLEND))
	if focusAlpha <= 0 then
		focusLimb = nil
	end
end

local function updateThirdPersonAlpha(deltaTime: number)
	local target = if thirdPersonEnabled then 1 else 0
	thirdPersonAlpha = approach(
		thirdPersonAlpha,
		target,
		deltaTime / math.max(Config.Camera.ThirdPersonBlend, MIN_BLEND)
	)
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

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= Config.Camera.ToggleKey then
			return
		end
		-- A setting, not a hold: this latches until pressed again.
		thirdPersonEnabled = not thirdPersonEnabled
	end)

	-- Camera priority runs after input is gathered and before the frame is drawn,
	-- which is where a camera update belongs. On RenderStepped it would be one
	-- frame stale by the time anything rendered.
	RunService:BindToRenderStep("ClimberCamera", Enum.RenderPriority.Camera.Value, function(deltaTime: number)
		local camera = activeCamera()
		if not camera then
			return
		end

		local headPart = head
		if not headPart then
			camera.CFrame = bootstrapCFrame
			return
		end

		updateStabilised(headPart, deltaTime)
		updateFocusAlpha(deltaTime)
		updateThirdPersonAlpha(deltaTime)

		local pose = restPose(headPart)

		-- Copied out before the guard so the narrowing holds across the call.
		local limb = focusLimb
		if limb and focusAlpha > 0 then
			pose = blendPoses(pose, focusPose(limb, pose), ease(focusAlpha))
		end

		camera.CFrame = poseToCFrame(pose)
	end)
end

return CameraController
