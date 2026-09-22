--!strict

-- Player -> limb mapping. This module is the single source of truth; nothing else
-- stores it. Other server modules call GetOwner/OwnsLimb rather than keeping a copy.
--
-- It also owns the session roster, the grace window and the lock, because "who is in
-- this run" and "who owns which limb" are the same question asked twice, and
-- splitting them across two modules is how the mapping ends up with a second copy.
--
-- The per-player attribute written below is a replication channel, not a second
-- store: the client needs to know which limbs to listen for keys on, and only this
-- module ever writes it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Climber.Config)
local Types = require(ReplicatedStorage.Climber.Types)

type LimbId = Types.LimbId

local ATTRIBUTE_PREFIX = Config.Net.LimbOwnershipAttributePrefix
local LIMB_ORDER = Config.Input.LimbOrder

-- Assignment by headcount, indexed by join order. Fixed rather than negotiated:
-- the build order has no lobby, so there is nowhere for players to choose.
--
-- Player 1 holds ArmR in every row and arms go out before legs, so a player's first
-- limb does not move as the headcount changes. This is a layout rather than a
-- tunable, which is why it is here and not in Config.
local LAYOUT: { { { LimbId } } } = {
	[1] = { { "ArmR", "ArmL", "LegR", "LegL" } },
	[2] = { { "ArmR", "LegR" }, { "ArmL", "LegL" } },
	[3] = { { "ArmR", "LegR" }, { "ArmL" }, { "LegL" } },
	[4] = { { "ArmR" }, { "ArmL" }, { "LegR" }, { "LegL" } },
}

local MAX_ASSIGNED = #LAYOUT

local LimbAssignment = {}

local ownerByLimb: { [LimbId]: Player } = {}

-- Everyone in the run, in join order. Before the lock this is the waiting list; the
-- grace window turns it into the roster. Players who arrive after the lock are
-- spectators and are in neither.
local roster: { Player } = {}
local locked = false

-- Invalidates a pending grace window. Bumped whenever the waiting list empties, so
-- a window opened by a player who then quit cannot start a run for whoever follows
-- them in, part-way through that player's own window.
local graceToken = 0

local function indexOf(player: Player): number?
	for index, candidate in roster do
		if candidate == player then
			return index
		end
	end
	return nil
end

local function setOwner(limbId: LimbId, player: Player?)
	local previous = ownerByLimb[limbId]
	if previous == player then
		return
	end

	if previous then
		previous:SetAttribute(ATTRIBUTE_PREFIX .. limbId, nil)
	end

	ownerByLimb[limbId] = player

	if player then
		player:SetAttribute(ATTRIBUTE_PREFIX .. limbId, true)
	end
end

local function limbCount(player: Player): number
	local count = 0
	for _, owner in ownerByLimb do
		if owner == player then
			count += 1
		end
	end
	return count
end

-- Assigns from the layout table and locks the session. Anyone who left during the
-- grace window is already off the roster, so the headcount here is live. Past four,
-- the extra players stay on the roster unassigned -- they spectate, but they are
-- still in the session and so are still candidates for an orphaned limb.
local function beginRun()
	locked = true

	local layout = LAYOUT[math.min(#roster, MAX_ASSIGNED)]
	for index, limbs in layout do
		local player = roster[index]
		if player then
			for _, limbId in limbs do
				setOwner(limbId, player)
			end
		end
	end
end

-- The player holding the fewest limbs, ties broken by join order. Called once per
-- orphan, so a departing pair-holder's two limbs spread across two players rather
-- than both landing on whoever happened to be emptiest first.
local function leastLoaded(): Player?
	local best: Player? = nil
	local bestCount = math.huge

	for _, player in roster do
		local count = limbCount(player)
		if count < bestCount then
			best = player
			bestCount = count
		end
	end

	return best
end

function LimbAssignment.GetOwner(limbId: LimbId): Player?
	return ownerByLimb[limbId]
end

function LimbAssignment.OwnsLimb(player: Player, limbId: LimbId): boolean
	return ownerByLimb[limbId] == player
end

function LimbAssignment.IsLocked(): boolean
	return locked
end

-- Joins the waiting list, or does nothing at all if the run has already locked --
-- decision 1, no mid-run joining. The first player to arrive opens the grace window
-- that will lock the session.
function LimbAssignment.PlayerJoined(player: Player)
	if locked or indexOf(player) then
		return
	end

	table.insert(roster, player)
	if #roster > 1 then
		return
	end

	graceToken += 1
	local token = graceToken

	task.delay(Config.Session.LobbyGraceSeconds, function()
		if token == graceToken and not locked and #roster > 0 then
			beginRun()
		end
	end)
end

-- Drops a player and hands their limbs to whoever is left. Returns every limb that
-- changed hands or went unowned, so the caller can settle whatever state the old
-- owner left those limbs in.
--
-- Limbs already held by remaining players never move. The result is therefore not
-- the layout row for the new headcount, which is deliberate: pulling a limb out of
-- someone's hands mid-climb is worse than an uneven split.
function LimbAssignment.PlayerLeft(player: Player): { LimbId }
	local index = indexOf(player)
	if index then
		table.remove(roster, index)
	end

	-- Walked in LIMB_ORDER rather than table order so the same disconnect produces
	-- the same split every time.
	local orphans: { LimbId } = {}
	for _, limbId in LIMB_ORDER do
		if ownerByLimb[limbId] == player then
			table.insert(orphans, limbId)
		end
	end

	for _, limbId in orphans do
		setOwner(limbId, leastLoaded())
	end

	-- Nobody left means no run left. Re-opening for the next joiner is not mid-run
	-- joining, and without it a server everyone has quit stays dead until restart.
	if #roster == 0 then
		locked = false
		graceToken += 1
	end

	return orphans
end

-- The attribute name a client reads to find out whether it owns a limb.
function LimbAssignment.AttributeFor(limbId: LimbId): string
	return ATTRIBUTE_PREFIX .. limbId
end

return LimbAssignment
