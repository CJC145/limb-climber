--!strict

-- Client entry point. Mirrors the existing Bootstrap.server.luau: the modules under
-- Climber/ are all ModuleScripts, so something has to start them.

local Climber = script.Parent.Climber

local CameraController = require(Climber.CameraController)
local TargetReticle = require(Climber.TargetReticle)
local InputRouter = require(Climber.InputRouter)
local HUD = require(Climber.HUD)

CameraController.Start()
TargetReticle.Start()
InputRouter.Start()
HUD.Start()
