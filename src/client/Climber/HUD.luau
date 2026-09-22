--!strict

-- Stamina bars, shared inventory, limb ownership indicators.
--
-- Phase 3 builds the ownership indicator only, and builds it as plain text. Stamina
-- is phase 5 and the shared inventory is phase 6; neither is stubbed here.
--
-- Decision 5 says the HUD is how limb intent gets communicated without voice chat.
-- That is a phase 4 job -- it needs the focus-cam blend to have something to show.
-- What this does is narrower: tell the player which limbs answer to them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Climber.Config)
local Types = require(ReplicatedStorage.Climber.Types)

type LimbId = Types.LimbId

local HUD = {}

-- Display names. "ArmR" is what the code calls it; nobody should have to read that
-- off a screen while hanging from a cliff.
local LIMB_LABEL: { [LimbId]: string } = {
	ArmR = "Right arm",
	ArmL = "Left arm",
	LegR = "Right leg",
	LegL = "Left leg",
}

local function createGui(): TextLabel
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LimbOwnership"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local label = Instance.new("TextLabel")
	label.Name = "Limbs"
	label.AnchorPoint = Vector2.new(0, 1)
	label.Position = UDim2.new(0, 16, 1, -16)
	label.Size = UDim2.fromOffset(240, 96)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Bottom
	label.RichText = false
	label.Text = ""
	label.Parent = screenGui

	return label
end

local function ownedText(): string
	local player = Players.LocalPlayer

	local lines: { string } = {}
	for _, limbId in Config.Input.LimbOrder do
		if player:GetAttribute(Config.Net.LimbOwnershipAttributePrefix .. limbId) == true then
			table.insert(lines, `{LIMB_LABEL[limbId]}  [{Config.Input.LimbKeys[limbId].Name}]`)
		end
	end

	if #lines == 0 then
		-- Covers both states where a player holds nothing: waiting out the grace
		-- window before the run locks, and spectating because it locked without them.
		-- They look identical from here and the distinction does not change what the
		-- player can do, so the text does not try to tell them apart.
		return "No limbs assigned"
	end

	-- Mirrors InputRouter: Space is an alias only while exactly one limb is owned.
	if #lines == 1 then
		table.insert(lines, `or [{Config.Input.SoloLimbKey.Name}]`)
	end

	return "YOUR LIMBS\n" .. table.concat(lines, "\n")
end

function HUD.Start()
	local label = createGui()
	local player = Players.LocalPlayer

	local function render()
		label.Text = ownedText()
	end

	-- One signal per limb. LimbAssignment writes these attributes on assignment and
	-- on every reassignment, so inheriting a limb from a disconnect redraws this
	-- without anything else having to say so.
	for _, limbId in Config.Input.LimbOrder do
		local attribute = Config.Net.LimbOwnershipAttributePrefix .. limbId
		player:GetAttributeChangedSignal(attribute):Connect(render)
	end

	render()
end

return HUD
