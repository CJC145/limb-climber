--!strict

-- Stamina bars and limb ownership indicators. The shared inventory is phase 6 and is
-- not stubbed here.
--
-- Phase 5 turns this from a text label into a row per limb, because it is now
-- carrying two jobs that phase 3's version was not.
--
-- The first is stamina, which only makes sense as a bar. A number counting down is
-- something to read; a bar draining is something to notice out of the corner of an
-- eye while looking at a wall, which is the only way it will ever actually be used.
--
-- The second is decision 5, and it is the more important of the two. The design doc
-- named the focus-cam blend as the non-verbal signal that a player was about to move
-- a limb. Phase 4 removed the focus cam -- correctly; the blend was only ever visible
-- to the player performing it, so it never carried the decision it was credited with
-- -- and the doc then puts the job here in as many words: decision 5 "now rests
-- entirely on the HUD's limb-intent indicator" and "it must ship in phase 5".
--
-- That is why there is a row for all four limbs and not just the player's own. A
-- player watching their partner's arm go amber is the entire mechanism by which this
-- game is playable without voice chat.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Climber.Config)
local Net = require(ReplicatedStorage.Climber.Net)
local Types = require(ReplicatedStorage.Climber.Types)

type LimbId = Types.LimbId
type GripState = Types.GripState

local HUD = {}

-- Display names. "ArmR" is what the code calls it; nobody should have to read that
-- off a screen while hanging from a cliff.
--
-- CROSSED ON PURPOSE. The model's R and L parts are named the wrong way round for a
-- body facing -Z: every *R part sits at -X, which is the climber's own left. The
-- label says the side the player sees move, not the side the id claims.
local LIMB_LABEL: { [LimbId]: string } = {
	ArmR = "Left arm",
	ArmL = "Right arm",
	LegR = "Left leg",
	LegL = "Right leg",
}

-- The pull chord, as a player reads it. Config lists both shift keys separately, and
-- "LeftShift" is an enum name rather than something to print.
local PULL_HINT = "Shift+key: pull"

-- The three grip states, as a colour and as a word.
--
-- Both, not either. Colour is what gets noticed in peripheral vision, which is the
-- whole point of the indicator, but amber against green is one of the two pairs most
-- colour-blind players cannot separate -- and a signal a player cannot read is a
-- signal decision 5 does not have. The word is the one that is actually legible;
-- the colour is what makes them look at it.
local STATE_COLOUR: { [GripState]: Color3 } = {
	Free = Color3.fromRGB(110, 114, 120),
	Reaching = Color3.fromRGB(255, 176, 46),
	Gripped = Color3.fromRGB(96, 208, 112),
}

local STATE_WORD: { [GripState]: string } = {
	-- Free is the resting state of every limb that is not doing anything, so naming it
	-- would fill the panel with a word carrying no information.
	Free = "",
	Reaching = "reaching",
	Gripped = "gripped",
}

local STAMINA_COLOUR = Color3.fromRGB(96, 208, 112)

-- Below MinToGrip a limb cannot take a hold at all, so the bar turning is not a
-- warning that exhaustion is coming -- it is the line itself. Deliberately tied to
-- the Config value rather than a separate display threshold, so the colour cannot
-- drift away from the rule it is reporting.
local STAMINA_LOW_COLOUR = Color3.fromRGB(226, 88, 72)

local OWNED_TEXT = Color3.fromRGB(255, 255, 255)
local UNOWNED_TEXT = Color3.fromRGB(150, 154, 160)

local ROW_HEIGHT = 20
local PANEL_WIDTH = 272
local NAME_WIDTH = 132
local RIGHT_X = 148
local RIGHT_WIDTH = 124

type Row = {
	dot: Frame,
	name: TextLabel,
	track: Frame,
	fill: Frame,
	state: TextLabel,
}

local function createRow(parent: Frame, order: number): Row
	local frame = Instance.new("Frame")
	frame.Name = "Row"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.LayoutOrder = order
	frame.Parent = parent

	local dot = Instance.new("Frame")
	dot.Name = "State"
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.new(0, 0, 0.5, 0)
	dot.Size = UDim2.fromOffset(8, 8)
	dot.BorderSizePixel = 0
	dot.Parent = frame

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = dot

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.AnchorPoint = Vector2.new(0, 0.5)
	name.Position = UDim2.new(0, 16, 0.5, 0)
	name.Size = UDim2.fromOffset(NAME_WIDTH, ROW_HEIGHT)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.Code
	name.TextSize = 14
	name.TextStrokeTransparency = 0.5
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.RichText = false
	name.Parent = frame

	-- The right-hand region holds one of two things and never both: a stamina bar for
	-- a limb this player owns, or the state word for one they do not. They share a
	-- position because they are the same column -- what that column says just depends
	-- on whether the limb is yours.
	local track = Instance.new("Frame")
	track.Name = "Stamina"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, RIGHT_X, 0.5, 0)
	track.Size = UDim2.fromOffset(RIGHT_WIDTH, 8)
	track.BackgroundColor3 = Color3.new(0, 0, 0)
	track.BackgroundTransparency = 0.5
	track.BorderSizePixel = 0
	track.Parent = frame

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 2)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = STAMINA_COLOUR
	fill.BorderSizePixel = 0
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 2)
	fillCorner.Parent = fill

	local state = Instance.new("TextLabel")
	state.Name = "Intent"
	state.AnchorPoint = Vector2.new(0, 0.5)
	state.Position = UDim2.new(0, RIGHT_X, 0.5, 0)
	state.Size = UDim2.fromOffset(RIGHT_WIDTH, ROW_HEIGHT)
	state.BackgroundTransparency = 1
	state.Font = Enum.Font.Code
	state.TextSize = 14
	state.TextStrokeTransparency = 0.5
	state.TextXAlignment = Enum.TextXAlignment.Left
	state.RichText = false
	state.Text = ""
	state.Parent = frame

	return {
		dot = dot,
		name = name,
		track = track,
		fill = fill,
		state = state,
	}
end

local function createGui(): (TextLabel, { [LimbId]: Row })
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ClimberHUD"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Limbs"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 16, 1, -16)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, ROW_HEIGHT * 5)
	panel.BackgroundTransparency = 1
	panel.Parent = screenGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	title.LayoutOrder = 0
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Code
	title.TextSize = 14
	title.TextColor3 = UNOWNED_TEXT
	title.TextStrokeTransparency = 0.5
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.RichText = false
	title.Text = ""
	title.Parent = panel

	local rows: { [LimbId]: Row } = {}
	for index, limbId in Config.Input.LimbOrder do
		rows[limbId] = createRow(panel, index)
	end

	return title, rows
end

function HUD.Start()
	local player = Players.LocalPlayer
	local title, rows = createGui()

	-- Free at full is the truth for a rig nobody has touched, so a client that draws
	-- this before the first broadcast arrives is not drawing a guess. The server
	-- broadcasts all four limbs unconditionally at Config.Net.LimbStateMaxPerSecond,
	-- so a client that joined mid-climb is corrected within a tenth of a second.
	local gripState: { [LimbId]: GripState } = {}
	local stamina: { [LimbId]: number } = {}

	for _, limbId in Config.Input.LimbOrder do
		gripState[limbId] = "Free"
		stamina[limbId] = Config.Stamina.Max
	end

	local function ownsLimb(limbId: LimbId): boolean
		return player:GetAttribute(Config.Net.LimbOwnershipAttributePrefix .. limbId) == true
	end

	local function ownedCount(): number
		local count = 0
		for _, limbId in Config.Input.LimbOrder do
			if ownsLimb(limbId) then
				count += 1
			end
		end
		return count
	end

	local function render()
		-- Mirrors InputRouter: Space is an alias only while exactly one limb is owned,
		-- so the hint appears under exactly the same condition the key works under.
		local owned = ownedCount()
		local showSoloKey = owned == 1

		-- Both states where a player holds nothing look identical from here -- waiting
		-- out the grace window, and spectating because it locked without them -- and
		-- the distinction does not change what they can do, so the text does not try
		-- to tell them apart.
		--
		-- The pull hint rides on the title rather than on every row: it is the same
		-- chord for every limb, and four copies of it would crowd out the stamina bars.
		-- Only for a player with limbs, who is the only one it works for.
		title.Text = if owned > 0 then `YOUR LIMBS  {PULL_HINT}` else "LIMBS  (none assigned)"

		for _, limbId in Config.Input.LimbOrder do
			local row = rows[limbId]
			local mine = ownsLimb(limbId)
			local state = gripState[limbId]

			row.dot.BackgroundColor3 = STATE_COLOUR[state]
			row.name.TextColor3 = if mine then OWNED_TEXT else UNOWNED_TEXT

			if mine then
				local key = Config.Input.LimbKeys[limbId].Name
				row.name.Text = if showSoloKey
					then `{LIMB_LABEL[limbId]} [{key}/{Config.Input.SoloLimbKey.Name}]`
					else `{LIMB_LABEL[limbId]} [{key}]`
			else
				row.name.Text = LIMB_LABEL[limbId]
			end

			row.track.Visible = mine
			row.state.Visible = not mine

			if mine then
				local value = stamina[limbId]
				row.fill.Size = UDim2.fromScale(value / Config.Stamina.Max, 1)
				row.fill.BackgroundColor3 = if value < Config.Stamina.MinToGrip
					then STAMINA_LOW_COLOUR
					else STAMINA_COLOUR
			else
				row.state.Text = STATE_WORD[state]
				row.state.TextColor3 = STATE_COLOUR[state]
			end
		end
	end

	-- Grip state changes arrive the moment they happen; stamina arrives on the server's
	-- capped stream. Both land here, and redrawing four rows is cheap enough that
	-- separating the two would only be a way to get one of them wrong.
	Net.LimbState.OnClientEvent:Connect(function(limbId: any, state: any, value: any)
		if gripState[limbId] == nil then
			return
		end

		gripState[limbId] = state :: GripState
		stamina[limbId] = value :: number
		render()
	end)

	-- One signal per limb. LimbAssignment writes these attributes on assignment and on
	-- every reassignment, so inheriting a limb from a disconnect redraws this without
	-- anything else having to say so.
	for _, limbId in Config.Input.LimbOrder do
		local attribute = Config.Net.LimbOwnershipAttributePrefix .. limbId
		player:GetAttributeChangedSignal(attribute):Connect(render)
	end

	render()
end

return HUD
