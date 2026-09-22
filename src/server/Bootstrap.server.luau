--!strict

-- Server entry point: build the rig, run the session lifecycle, and route validated
-- intent into GripService.
--
-- Phase 3 replaces phase 1's "first player in takes everything" with a real roster.
-- The rules and the lock live in LimbAssignment; what is here is the wiring.
--
-- Phase 5 adds AnchorService to that wiring and nothing else. Stamina and falling are
-- continuous, so both run off their own heartbeats inside the modules that own them
-- rather than off a loop here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Climber.Config)
local Net = require(ReplicatedStorage.Climber.Net)
local Types = require(ReplicatedStorage.Climber.Types)

local AnchorService = require(ServerScriptService.Climber.AnchorService)
local ClimberRig = require(ServerScriptService.Climber.ClimberRig)
local GripService = require(ServerScriptService.Climber.GripService)
local LimbAssignment = require(ServerScriptService.Climber.LimbAssignment)

Players.CharacterAutoLoads = false

local rig = ClimberRig.Build()

-- GripService first. AnchorService reads the gripped count on every heartbeat and
-- would see an unbound service on the frame between the two otherwise.
GripService.Bind(rig)
AnchorService.Bind(rig)

local MIN_INTENT_INTERVAL = 1 / Config.Net.LimbIntentMaxPerSecond
local MIN_PULL_INTERVAL = 1 / Config.Net.LimbPullMaxPerSecond

-- Per player *and per limb*. A solo player holds up to four limbs at once and each
-- one streams independently, so a single per-player budget would let whichever limb
-- fired first in the window starve the rest.
local lastIntentAt: { [Player]: { [Types.LimbId]: number } } = {}
local lastPullAt: { [Player]: { [Types.LimbId]: number } } = {}

local function isFinite(value: Vector3): boolean
	for _, component in { value.X, value.Y, value.Z } do
		if component ~= component or math.abs(component) == math.huge then
			return false
		end
	end
	return true
end

Net.LimbIntent.OnServerEvent:Connect(function(player: Player, limbId: any, targetPosition: any, aimOrigin: any, isHeld: any)
	if typeof(limbId) ~= "string" or typeof(isHeld) ~= "boolean" then
		return
	end

	if typeof(targetPosition) ~= "Vector3" or typeof(aimOrigin) ~= "Vector3" then
		return
	end

	local limb = limbId :: Types.LimbId
	if GripService.GetState(limb) == nil then
		return
	end

	if not LimbAssignment.OwnsLimb(player, limb) then
		return
	end

	-- Both, because both reach the maths. A non-finite origin would poison the ray
	-- direction and put a nan into an AlignPosition, which fails somewhere that looks
	-- nothing like here.
	if not isFinite(targetPosition) or not isFinite(aimOrigin) then
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

	-- Clamped rather than rejected, so aiming past the limit stalls the hand at full
	-- stretch instead of dropping the intent and making the arm stutter.
	--
	-- The envelope is per limb and measured off the rig, so this is also the whole of
	-- the server's bound on how far a target may be: whatever a client sends, the
	-- point the align actually chases is inside one limb's own reach. There is no
	-- second, looser check to keep in step with it.
	--
	-- The origin steers the clamp without loosening it. It decides which way the
	-- point moves to get inside the envelope, never how big the envelope is, so a
	-- client that lies about where it is looking still cannot ask for a target its
	-- limb could not have reached honestly.
	local clamped = ClimberRig.ClampToReach(rig.limbs[limb], aimOrigin, targetPosition)

	GripService.SetIntent(limb, clamped, isHeld)
end)

-- Pull is per player, not per body. A player may only drive the hinges of limbs they
-- own, so in a four-player run nobody can ascend alone -- an arm hauling against
-- three limbs nobody is pulling with just loads them. Coordinating the pull is the
-- coordination problem the game is about, and this ownership check is where it is
-- actually enforced.
Net.LimbPull.OnServerEvent:Connect(function(player: Player, limbId: any, isPulling: any)
	if typeof(limbId) ~= "string" or typeof(isPulling) ~= "boolean" then
		return
	end

	local limb = limbId :: Types.LimbId
	if GripService.GetState(limb) == nil then
		return
	end

	if not LimbAssignment.OwnsLimb(player, limb) then
		return
	end

	-- Only the starting edge is throttled, for the same reason the held intent stream
	-- is and with worse consequences if it were not: a dropped "stopped" would leave
	-- a motor running with no further message able to switch it off.
	if isPulling then
		local now = os.clock()

		local perLimb = lastPullAt[player] or {}
		lastPullAt[player] = perLimb

		local last = perLimb[limb]
		if last and now - last < MIN_PULL_INTERVAL then
			return
		end
		perLimb[limb] = now
	end

	GripService.SetPull(limb, isPulling)
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
	lastPullAt[player] = nil

	-- Orphans are whatever the departing player held. They have new owners by the
	-- time this returns, but a limb they quit mid-reach is still reaching, and the
	-- intent stream that would have ended it left with them.
	for _, limbId in LimbAssignment.PlayerLeft(player) do
		-- A pull is worse than a stranded reach, because it is a held state with no
		-- stream behind it: the key-up that would have ended it left with the player,
		-- and the motor would drive until the limb happened to lose its grip. The new
		-- owner inherits a limb at rest, not one already hauling.
		GripService.SetPull(limbId, false)

		GripService.AbandonReach(limbId)
	end
end)
