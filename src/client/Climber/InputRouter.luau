--!strict

-- Keys to limb intents, for this player's limbs only.
--
-- Ownership is read from the attribute LimbAssignment publishes on the player.
-- This module keeps no mapping of its own -- it asks, every time. A player with no
-- limbs is a spectator and simply never passes that check.
--
-- A limb key means one of two things. Bare, it is the reach from phase 1: hold to
-- let go and aim, release to grip. Held together with shift, in either order, it is
-- a pull on a limb that is already gripped.
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

-- The same, for pulls. A held key is in exactly one of the four key tables here --
-- reaching, pulling, pending or spent -- and moves between them only forward.
local pulling: { [LimbId]: true } = {}
local pullByKey: { [Enum.KeyCode]: LimbId } = {}

-- A bare limb key on a gripped limb, not yet decided. Shift may still be coming, and
-- a reach cannot wait for it: the first held intent the server sees drops the grip,
-- which would leave a late shift with nothing to haul on. So the press sits here for
-- Config.Input.PullGraceSeconds and sends nothing. Shift inside the window makes it
-- a pull; the window running out makes it the reach it would always have been.
--
-- Only for a gripped limb, because only a grip has anything to lose. A free limb's
-- reach starts at once, exactly as before.
local pending: { [LimbId]: true } = {}
local pendingByKey: { [Enum.KeyCode]: LimbId } = {}
local pendingSince: { [LimbId]: number } = {}

-- A pull that shift ended while the limb key was still down. The key does nothing
-- more until it comes up. It must never fall back into a reach -- a reach begins by
-- dropping the hold the player was just hauling on -- and pressing shift again does
-- not restart it either; the limb key has to be pressed again.
local spent: { [LimbId]: true } = {}
local spentByKey: { [Enum.KeyCode]: LimbId } = {}

-- The last grip state the server broadcast for each limb, so a press knows whether
-- it has a grip to protect. Read from the same LimbState stream the HUD draws.
local limbState: { [LimbId]: Types.GripState } = {}

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

-- Polled rather than tracked through its own key events -- at the press, and every
-- frame while a press is pending or pulling. Shift can be pressed before this module
-- ever sees a limb key, and can be held across an alt-tab that eats the key-up, so
-- asking the service for the live state is more reliable than keeping a copy of it.
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

-- Any gesture at all already running on this limb, through any key. A solo player
-- can reach one limb through its own key and through Space; whichever arrives first
-- owns the limb, and the second press is ignored so that releasing one key cannot
-- end a gesture the other is still holding.
local function limbBusy(limbId: LimbId): boolean
	return held[limbId] ~= nil or pulling[limbId] ~= nil or pending[limbId] ~= nil or spent[limbId] ~= nil
end

local function startReach(key: Enum.KeyCode, limbId: LimbId)
	held[limbId] = true
	heldByKey[key] = limbId
end

local function startPull(key: Enum.KeyCode, limbId: LimbId)
	pulling[limbId] = true
	pullByKey[key] = limbId
	Net.LimbPull:FireServer(limbId, true)
end

local function endPull(key: Enum.KeyCode, limbId: LimbId)
	pullByKey[key] = nil
	pulling[limbId] = nil
	Net.LimbPull:FireServer(limbId, false)
end

local function clearPending(key: Enum.KeyCode, limbId: LimbId)
	pendingByKey[key] = nil
	pending[limbId] = nil
	pendingSince[limbId] = nil
end

function InputRouter.Start()
	Net.LimbState.OnClientEvent:Connect(function(limbId: any, state: any)
		if Config.Input.LimbKeys[limbId] == nil then
			return
		end
		limbState[limbId :: LimbId] = state :: Types.GripState
	end)

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
		if not limbId or not ownsLimb(limbId) or limbBusy(limbId) then
			return
		end

		-- Space resolves through limbForKey exactly as a limb key does, so a solo
		-- player's Space is an alias in every mode rather than only in one.
		if pullModifierDown() then
			startPull(input.KeyCode, limbId)
			return
		end

		if limbState[limbId] == "Gripped" then
			pending[limbId] = true
			pendingByKey[input.KeyCode] = limbId
			pendingSince[limbId] = os.clock()
			return
		end

		startReach(input.KeyCode, limbId)
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
			endPull(input.KeyCode, pullLimb)
			return
		end

		-- A tap on a gripped limb shorter than the grace window. Nothing was sent, so
		-- nothing needs undoing and the hold is kept. Before the window existed the
		-- same tap dropped the grip for a frame and re-gripped wherever the hand was,
		-- which came to the same thing by a longer route.
		local pendingLimb = pendingByKey[input.KeyCode]
		if pendingLimb then
			clearPending(input.KeyCode, pendingLimb)
			return
		end

		local spentLimb = spentByKey[input.KeyCode]
		if spentLimb then
			spentByKey[input.KeyCode] = nil
			spent[spentLimb] = nil
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
		local modifierDown = pullModifierDown()

		-- Before the reach stream below, so a press that becomes a reach this frame
		-- sends its first intent this frame rather than the next.
		for key, limbId in pendingByKey do
			if modifierDown then
				clearPending(key, limbId)
				startPull(key, limbId)
			elseif now - pendingSince[limbId] >= Config.Input.PullGraceSeconds then
				clearPending(key, limbId)
				startReach(key, limbId)
			end
		end

		-- Shift let go mid-pull ends the pull and parks the key. See `spent`.
		if not modifierDown then
			for key, limbId in pullByKey do
				endPull(key, limbId)
				spent[limbId] = true
				spentByKey[key] = limbId
			end
		end

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
