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
	local rig = workspace:WaitForChild(Config.Rig.ModelName)
	local torso = rig:WaitForChild("Torso") :: BasePart

	local camera = workspace.CurrentCamera
	while not camera do
		task.wait()
		camera = workspace.CurrentCamera
	end

	-- With CharacterAutoLoads off there is no character for the camera to follow,
	-- so it has to be driven explicitly or it sits at the origin.
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(torso.Position + Config.Camera.Phase1Offset, torso.Position)
end

return CameraController
