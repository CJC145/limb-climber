--!strict

-- Keys to limb intents, for this player's limbs only.
--
-- Ownership is read from the attribute LimbAssignment publishes on the player.
-- This module keeps no mapping of its own -- it asks, every time. A player with no
-- limbs is a spectator and simply never passes that check.
--
-- A limb key means one of two things depending on whether shift is down when it is
-- pressed. Bare, it is the reach from phase 1: hold to let go and aim, release to
-- grip. With shift, it is a pull on a limb that is already gripped.
--
-- Shift has to be a modifier rather than a key of its own, and pull has to be a
-- different chord rather than a second press of the same key, because holding a limb
-- key is what *releases* that limb's grip -- and a pull has nothing to haul on
-- without one. The two gestures are opposites wearing the same key.
--
-- A and D roll the torso, and are the one input here that is not a limb's. There is
-- one body and every assigned player shares it, so these go to the server as a vote
-- rather than as a command -- the torso does the net of what it is asked.

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

-- The same, for pulls. A key is in one of these two pairs of tables or neither,
-- never both: shift at the moment of the press decides which, and the press is the
-- only time it is asked.
--
-- Deciding at press time is not merely consistent with the reach binding above, it
-- is the only workable answer. Shift can be let go in the middle of a hold, and
-- re-resolving would turn a pull into a reach without a keypress -- which, because
-- holding a limb key is what *releases* a grip, would drop the hold the player was
-- hauling on. Letting go of shift mid-pull does nothing. The limb key ends it.
local pulling: { [LimbId]: true } = {}
local pullByKey: { [Enum.KeyCode]: LimbId } = {}

-- Roll is not a limb and so is tracked by key rather than by limb: one torso, and
-- both roll keys can be down at once. Holding both is not an error and not ignored --
-- it nets to zero, which is what pressing left and right together should do.
local rollKeysDown: { [Enum.KeyCode]: number } = {}
local rollSent = 0

local function ownsLimb(limbId: LimbId): boolean
	local attribute = Config.Net.LimbOwnershipAttributePrefix .. limbId
	return Players.LocalPlayer:GetAttribute(attribute) == true
end

-- Sends the net of the roll keys currently down, and only when it changes. The state
-- is held, not streamed: the server keeps applying the torque until told otherwise,
-- so there is nothing to repeat every frame.
local function updateRoll()
	local net = 0
	for _, value in rollKeysDown do
		net += value
	end

	local direction = math.clamp(net, -1, 1)
	if direction == rollSent then
		return
	end

	rollSent = direction
	Net.RollIntent:FireServer(direction)
end

-- Polled at the moment of the press rather than tracked through its own key events.
-- Shift can be pressed before this module ever sees a limb key, and can be held
-- across an alt-tab that eats the key-up, so asking the service for the live state is
-- more reliable than keeping a copy of it.
local function pullModifierDown(): boolean
	for _, key in Config.Input.PullModifiers do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
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

	-- Which way each roll key turns the body. Positive is a roll to the left, matching
	-- the sign ClimberRig resolves against the rig's facing.
	local rollByKey: { [Enum.KeyCode]: number } = {
		[Config.Input.RollKeys.Left] = 1,
		[Config.Input.RollKeys.Right] = -1,
	}

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		-- Before the limb lookup, because a roll key is not a limb key and would fall
		-- straight out of the bottom of it.
		local roll = rollByKey[input.KeyCode]
		if roll then
			rollKeysDown[input.KeyCode] = roll
			updateRoll()
			return
		end

		local limbId = limbForKey(input.KeyCode)
		if not limbId or not ownsLimb(limbId) then
			return
		end

		-- Shift decides which of the two things this key press is. Space resolves
		-- through limbForKey exactly as a limb key does, so a solo player's Space is
		-- an alias in both modes rather than only in one -- shift-Space pulls that
		-- player's limb, and bare Space still reaches with it, unchanged from phase 3.
		if pullModifierDown() then
			-- Same guard as the reach below, for the same reason: a solo player can
			-- start one pull through two different keys.
			if pulling[limbId] then
				return
			end

			pulling[limbId] = true
			pullByKey[input.KeyCode] = limbId
			Net.LimbPull:FireServer(limbId, true)
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
		-- Unfiltered like everything else in here: whatever started has to be able to
		-- finish. A roll left running because its key-up was swallowed is a torso
		-- turning with nobody driving it.
		if rollKeysDown[input.KeyCode] then
			rollKeysDown[input.KeyCode] = nil
			updateRoll()
			return
		end

		-- Pulls next, and with no gameProcessedEvent filter for the same reason the
		-- reach below has none: whatever started has to be able to finish. A pull left
		-- running because its key-up was swallowed is a motor nobody can switch off.
		local pullLimb = pullByKey[input.KeyCode]
		if pullLimb then
			pullByKey[input.KeyCode] = nil
			pulling[pullLimb] = nil
			Net.LimbPull:FireServer(pullLimb, false)
			return
		end

		local limbId = heldByKey[input.KeyCode]
		if not limbId then
			return
		end

		held[limbId] = nil
		heldByKey[input.KeyCode] = nil
		lastSentAt[limbId] = nil

		-- Releasing the key is the grip attempt, so this one always goes out.
		Net.LimbIntent:FireServer(limbId, TargetReticle.GetTargetPosition(), TargetReticle.GetAimOrigin(), false)
	end)

	RunService.RenderStepped:Connect(function()
		local now = os.clock()

		for limbId in held do
			local last = lastSentAt[limbId]
			if last == nil or now - last >= minInterval then
				lastSentAt[limbId] = now
				Net.LimbIntent:FireServer(limbId, TargetReticle.GetTargetPosition(), TargetReticle.GetAimOrigin(), true)
			end
		end
	end)
end

return InputRouter
