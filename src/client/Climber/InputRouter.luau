--!strict

-- Keys to limb intents, for this player's limbs only.
--
-- Ownership is read from the attribute LimbAssignment publishes on the player.
-- This module keeps no mapping of its own -- it asks, every time.

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

local heldSince: { [LimbId]: number } = {}

local function ownsLimb(limbId: LimbId): boolean
	local attribute = Config.Net.LimbOwnershipAttributePrefix .. limbId
	return Players.LocalPlayer:GetAttribute(attribute) == true
end

function InputRouter.Start()
	local limbByKey: { [Enum.KeyCode]: LimbId } = {}
	for limbId, key in Config.Input.LimbKeys do
		limbByKey[key] = (limbId :: any) :: LimbId
	end

	-- The client caps its own send rate too. RenderStepped on a high-refresh display
	-- would otherwise run past the server's limit and have the extra calls dropped.
	local minInterval = 1 / Config.Net.LimbIntentMaxPerSecond
	local lastSentAt: { [LimbId]: number } = {}

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		local limbId = limbByKey[input.KeyCode]
		if not limbId or not ownsLimb(limbId) then
			return
		end

		heldSince[limbId] = os.clock()
	end)

	UserInputService.InputEnded:Connect(function(input)
		local limbId = limbByKey[input.KeyCode]
		if not limbId or heldSince[limbId] == nil then
			return
		end

		heldSince[limbId] = nil
		lastSentAt[limbId] = nil

		-- Releasing the key is the grip attempt, so this one always goes out.
		Net.LimbIntent:FireServer(limbId, TargetReticle.GetTargetPosition(), false)
	end)

	RunService.RenderStepped:Connect(function()
		local now = os.clock()

		for limbId in heldSince do
			local last = lastSentAt[limbId]
			if last == nil or now - last >= minInterval then
				lastSentAt[limbId] = now
				Net.LimbIntent:FireServer(limbId, TargetReticle.GetTargetPosition(), true)
			end
		end
	end)
end

return InputRouter
