--!strict

-- Phase 1 entry point: build the rig, hand its limbs to the first player in, and
-- route validated intent into GripService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Climber.Config)
local Net = require(ReplicatedStorage.Climber.Net)
local Types = require(ReplicatedStorage.Climber.Types)

local ClimberRig = require(ServerScriptService.Climber.ClimberRig)
local GripService = require(ServerScriptService.Climber.GripService)
local LimbAssignment = require(ServerScriptService.Climber.LimbAssignment)

Players.CharacterAutoLoads = false

local rig = ClimberRig.Build()
GripService.Bind(rig)

local MIN_INTENT_INTERVAL = 1 / Config.Net.LimbIntentMaxPerSecond

local lastIntentAt: { [Player]: number } = {}

local function isFinite(value: Vector3): boolean
	for _, component in { value.X, value.Y, value.Z } do
		if component ~= component or math.abs(component) == math.huge then
			return false
		end
	end
	return true
end

-- Keeps a target inside the limb's plausible reach. Clamped rather than rejected,
-- so aiming past the limit stalls the hand at full stretch instead of dropping the
-- intent and making the arm stutter.
local function clampToReach(target: Vector3): Vector3
	local origin = rig.torso.Position
	local offset = target - origin
	local distance = offset.Magnitude

	if distance <= Config.Grip.MaxTargetDistance or distance == 0 then
		return target
	end

	return origin + offset.Unit * Config.Grip.MaxTargetDistance
end

Net.LimbIntent.OnServerEvent:Connect(function(player: Player, limbId: any, targetPosition: any, isHeld: any)
	if typeof(limbId) ~= "string" or typeof(targetPosition) ~= "Vector3" or typeof(isHeld) ~= "boolean" then
		return
	end

	local limb = limbId :: Types.LimbId
	if GripService.GetState(limb) == nil then
		return
	end

	if not LimbAssignment.OwnsLimb(player, limb) then
		return
	end

	if not isFinite(targetPosition) then
		return
	end

	-- Throttle the held stream only. A release is the edge that ends the reach, and
	-- dropping one would strand the limb mid-reach with no way back.
	if isHeld then
		local now = os.clock()
		local last = lastIntentAt[player]
		if last and now - last < MIN_INTENT_INTERVAL then
			return
		end
		lastIntentAt[player] = now
	end

	GripService.SetIntent(limb, clampToReach(targetPosition), isHeld)
end)

Players.PlayerAdded:Connect(function(player)
	for limbId in rig.limbs do
		if LimbAssignment.GetOwner(limbId) == nil then
			LimbAssignment.Assign(player, limbId)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	LimbAssignment.ClearPlayer(player)
	lastIntentAt[player] = nil
end)
