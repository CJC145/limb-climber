--!strict

-- Player -> limb mapping. This module is the single source of truth; nothing else
-- stores it. Other server modules call GetOwner/OwnsLimb rather than keeping a copy.
--
-- Phase 1 is one player and one limb, so there is no lobby, no key negotiation and
-- no orphan reassignment here. Those are phase 3.
--
-- The per-player attribute written below is a replication channel, not a second
-- store: the client needs to know which limbs to listen for keys on, and only this
-- module ever writes it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Climber.Config)
local Types = require(ReplicatedStorage.Climber.Types)

type LimbId = Types.LimbId

local ATTRIBUTE_PREFIX = Config.Net.LimbOwnershipAttributePrefix

local LimbAssignment = {}

local ownerByLimb: { [LimbId]: Player } = {}

function LimbAssignment.Assign(player: Player, limbId: LimbId)
	local previous = ownerByLimb[limbId]
	if previous then
		previous:SetAttribute(ATTRIBUTE_PREFIX .. limbId, nil)
	end

	ownerByLimb[limbId] = player
	player:SetAttribute(ATTRIBUTE_PREFIX .. limbId, true)
end

function LimbAssignment.GetOwner(limbId: LimbId): Player?
	return ownerByLimb[limbId]
end

function LimbAssignment.OwnsLimb(player: Player, limbId: LimbId): boolean
	return ownerByLimb[limbId] == player
end

-- Clears everything a player owned. Phase 1 does not reassign the orphans -- a
-- solo run with nobody in it has nothing to reassign to.
function LimbAssignment.ClearPlayer(player: Player)
	for limbId, owner in ownerByLimb do
		if owner == player then
			ownerByLimb[limbId] = nil
		end
	end
end

-- The attribute name a client reads to find out whether it owns a limb.
function LimbAssignment.AttributeFor(limbId: LimbId): string
	return ATTRIBUTE_PREFIX .. limbId
end

return LimbAssignment
