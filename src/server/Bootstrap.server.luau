--!strict

-- Server entry point: build the rig, run the session lifecycle, and route validated
-- intent into GripService.
--
-- Phase 3 replaces phase 1's "first player in takes everything" with a real roster.
-- The rules and the lock live in LimbAssignment; what is here is the wiring.

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

-- Per player *and per limb*. A solo player holds up to four limbs at once and each
-- one streams independently, so a single per-player budget would let whichever limb
-- fired first in the window starve the rest.
local lastIntentAt: { [Player]: { [Types.LimbId]: number } } = {}

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

		local perLimb = lastIntentAt[player] or {}
		lastIntentAt[player] = perLimb

		local last = perLimb[limb]
		if last and now - last < MIN_INTENT_INTERVAL then
			return
		end
		perLimb[limb] = now
	end

	GripService.SetIntent(limb, clampToReach(targetPosition), isHeld)
end)

Players.PlayerAdded:Connect(function(player)
	-- ReplicationFocus normally defaults to the character's root part. There is no
	-- character here, so without this the client has no focus and, under
	-- StreamingEnabled, the rig and the wall never stream in at all. Harmless when
	-- streaming is off.
	player.ReplicationFocus = rig.torso

	-- Joins the waiting list, or is ignored if the session has already locked. A
	-- spectator needs nothing else from here: they get a camera and a reticle like
	-- everyone else, and no limb will ever answer their keys.
	LimbAssignment.PlayerJoined(player)
end)

Players.PlayerRemoving:Connect(function(player)
	lastIntentAt[player] = nil

	-- Orphans are whatever the departing player held. They have new owners by the
	-- time this returns, but a limb they quit mid-reach is still reaching, and the
	-- intent stream that would have ended it left with them.
	for _, limbId in LimbAssignment.PlayerLeft(player) do
		GripService.AbandonReach(limbId)
	end
end)
