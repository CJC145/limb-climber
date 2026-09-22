--!strict

-- Phase 1 camera only: a fixed vantage point framing the rig, which exists so the
-- mouse has something to cast a ray through.
--
-- The stabilised head-cam, the focus blend and the third-person toggle are phase 4.
-- None of them are stubbed in here -- this module gets rewritten then.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Climber.Config)

local CameraController = {}

function CameraController.Start()
	local camera = workspace.CurrentCamera
	while not camera do
		task.wait()
		camera = workspace.CurrentCamera
	end

	-- Aimed from Config rather than from the rig on purpose. With no character there
	-- is no replication focus until the camera is placed, so waiting for a rig part
	-- here deadlocks: the parts cannot stream in until the camera moves, and the
	-- camera cannot move until the parts arrive.
	--
	-- The phase 1 torso is anchored at exactly SpawnPosition and never moves, so this
	-- frames the same point the rig occupies. The moment the torso can move, this has
	-- to follow the real part instead.
	local focus = Config.Rig.SpawnPosition

	-- With CharacterAutoLoads off there is no character for the camera to follow,
	-- so it has to be driven explicitly or it sits at the origin.
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(focus + Config.Camera.Phase1Offset, focus)
end

return CameraController
