--!strict

-- Keys to limb intents, for this player's limbs only.
--
-- Ownership is read from the attribute LimbAssignment publishes on the player.
-- This module keeps no mapping of its own -- it asks, every time. A player with no
-- limbs is a spectator and simply never passes that check.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Climber.Config)
local Net = require(ReplicatedStorage.Climber.Net)
local Types = require(ReplicatedStorage.Climber.Types)

local TargetReticle = require(script.Parent.TargetReticle)

type LimbId = Types.LimbId

local InputRouter = {}

-- Which limbs are currently reaching, and which key started each reach. The binding
-- is recorded at press time rather than resolved again on release, because Space
-- resolves through ownership and ownership can change mid-hold -- inheriting a
-- second limb from a disconnect would otherwise strand the first one mid-reach.
local held: { [LimbId]: true } = {}
local heldByKey: { [Enum.KeyCode]: LimbId } = {}

local function ownsLimb(limbId: LimbId): boolean
	local attribute = Config.Net.LimbOwnershipAttributePrefix .. limbId
	return Players.LocalPlayer:GetAttribute(attribute) == true
end

-- Space is an alias, not a binding: it answers only for a player who owns exactly
-- one limb, which is the four-player case. Anyone holding two or more gets nothing
-- from it, because there would be no way to say which limb they meant.
local function soloOwnedLimb(): LimbId?
	local found: LimbId? = nil

	for _, limbId in Config.Input.LimbOrder do
		if ownsLimb(limbId) then
			if found then
				return nil
			end
			found = limbId
		end
	end

	return found
end

function InputRouter.Start()
	local limbByKey: { [Enum.KeyCode]: LimbId } = {}
	for limbId, key in Config.Input.LimbKeys do
		limbByKey[key] = limbId
	end

	local function limbForKey(key: Enum.KeyCode): LimbId?
		if key == Config.Input.SoloLimbKey then
			return soloOwnedLimb()
		end
		return limbByKey[key]
	end

	-- The client caps its own send rate too. RenderStepped on a high-refresh display
	-- would otherwise run past the server's limit and have the extra calls dropped.
	local minInterval = 1 / Config.Net.LimbIntentMaxPerSecond
	local lastSentAt: { [LimbId]: number } = {}

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		local limbId = limbForKey(input.KeyCode)
		if not limbId or not ownsLimb(limbId) then
			return
		end

		-- A solo-limb player can reach the same limb through its own key and through
		-- Space. Whichever arrives first owns the reach; the second press is ignored
		-- so that releasing one key cannot end a reach the other is still holding.
		if held[limbId] then
			return
		end

		held[limbId] = true
		heldByKey[input.KeyCode] = limbId
	end)

	UserInputService.InputEnded:Connect(function(input)
		local limbId = heldByKey[input.KeyCode]
		if not limbId then
			return
		end

		held[limbId] = nil
		heldByKey[input.KeyCode] = nil
		lastSentAt[limbId] = nil

		-- Releasing the key is the grip attempt, so this one always goes out.
		Net.LimbIntent:FireServer(limbId, TargetReticle.GetTargetPosition(), false)
	end)

	RunService.RenderStepped:Connect(function()
		local now = os.clock()

		for limbId in held do
			local last = lastSentAt[limbId]
			if last == nil or now - last >= minInterval then
				lastSentAt[limbId] = now
				Net.LimbIntent:FireServer(limbId, TargetReticle.GetTargetPosition(), true)
			end
		end
	end)
end

return InputRouter
