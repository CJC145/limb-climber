--!strict

-- Rig construction and network ownership.
--
-- Phase 2 replaces phase 1's script-built scaffolding with the modelled 14-part rig
-- in assets/climber.rbxm, mounted at ServerStorage/Assets by default.project.json.
--
-- The model is the authority on shape: part sizes, part positions and attachment
-- *positions* all come from it and are never written here. This module adds only the
-- things a saved model cannot carry -- constraints, mass properties, collision groups
-- and network ownership -- plus attachment *orientation*, which is a constraint frame
-- rather than a placement decision. See ORIENTATION below.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Climber.Config)
local Types = require(ReplicatedStorage.Climber.Types)

type LimbId = Types.LimbId

export type Limb = {
	limbId: LimbId,
	extremity: BasePart,
	gripAttachment: Attachment,
	align: AlignPosition,
}

export type Rig = {
	model: Model,
	torso: BasePart,
	limbs: { [LimbId]: Limb },
}

-- ORIENTATION -----------------------------------------------------------------
--
-- Every attachment in the model is identity-rotated: the human was asked for joint
-- locations, not constraint frames. Both constraint types read their axis off the
-- attachment frame, so the frames are set here and the positions left alone.
--
-- All of this assumes the model's parts are themselves identity-rotated, which they
-- are, and that the rig is placed with a pure translation, which Build does. Rotating
-- a part in the model would silently tilt these axes.

-- A BallSocketConstraint measures its cone around Attachment0's X axis, so that axis
-- has to point along the joint's rest direction. Otherwise the cone opens sideways
-- and the limb sits pinned against the edge of its own limit from the first frame.
local CONE_DOWN = CFrame.Angles(0, 0, -math.pi / 2) -- X -> -Y, for limbs hanging below the joint
local CONE_UP = CFrame.Angles(0, 0, math.pi / 2) -- X -> +Y, for the neck: the head rests above the torso

-- A HingeConstraint turns about its attachments' X axis, positively by the right-hand
-- rule. The model faces -Z, so about +X a positive angle swings a hanging segment
-- forward and about -X it swings backward. That axis choice is the entire difference
-- between an elbow and a knee, and it is what lets Config.JointLimits hold the doc's
-- unsigned anatomical ranges instead of engine sign conventions.
local HINGE_FORWARD = CFrame.identity -- axis +X: elbows
local HINGE_BACKWARD = CFrame.Angles(0, math.pi, 0) -- axis -X: knees

-- MASS ------------------------------------------------------------------------
--
-- Density and friction grades from the design doc's mass table, and which of the 14
-- parts draws from each. Iterating PART_GRADE is also what proves the template has
-- every part the code expects.

type Grade = { Density: number, Friction: number }

local GRADE: { [string]: Grade } = {
	Torso = { Density = Config.Mass.Torso, Friction = Config.Friction.Torso },
	Head = { Density = Config.Mass.Head, Friction = Config.Friction.Head },
	Upper = { Density = Config.Mass.UpperLimb, Friction = Config.Friction.UpperLimb },
	Lower = { Density = Config.Mass.LowerLimb, Friction = Config.Friction.LowerLimb },
	Extremity = { Density = Config.Mass.Extremity, Friction = Config.Friction.Extremity },
}

local PART_GRADE: { [string]: Grade } = {
	Torso = GRADE.Torso,
	Head = GRADE.Head,

	UpperArmR = GRADE.Upper,
	UpperArmL = GRADE.Upper,
	UpperLegR = GRADE.Upper,
	UpperLegL = GRADE.Upper,

	LowerArmR = GRADE.Lower,
	LowerArmL = GRADE.Lower,
	LowerLegR = GRADE.Lower,
	LowerLegL = GRADE.Lower,

	HandR = GRADE.Extremity,
	HandL = GRADE.Extremity,
	FootR = GRADE.Extremity,
	FootL = GRADE.Extremity,
}

-- COLLISION -------------------------------------------------------------------
--
-- Decision 4: the segments of one limb do not collide with each other, but limbs do
-- collide with the torso. One group per limb, made non-collidable with itself, buys
-- exactly that -- and it covers the directly-constrained pairs too, so it does not
-- matter whether the engine would have suppressed those on its own.
--
-- Head shares the torso's group. The doc calls it a camera anchor rather than a
-- hitbox, and the neck's two attachments sit 0.15 studs apart, so leaving head-torso
-- collision on would only fight the neck constraint.
--
-- Everything not listed here stays collidable: limb against core, limb against limb,
-- and every group against the world.

local CORE_GROUP = "ClimberCore"

local LIMB_GROUP: { [LimbId]: string } = {
	ArmR = "ClimberArmR",
	ArmL = "ClimberArmL",
	LegR = "ClimberLegR",
	LegL = "ClimberLegL",
}

local GROUP_MEMBERS: { [string]: { string } } = {
	[CORE_GROUP] = { "Torso", "Head" },
	[LIMB_GROUP.ArmR] = { "UpperArmR", "LowerArmR", "HandR" },
	[LIMB_GROUP.ArmL] = { "UpperArmL", "LowerArmL", "HandL" },
	[LIMB_GROUP.LegR] = { "UpperLegR", "LowerLegR", "FootR" },
	[LIMB_GROUP.LegL] = { "UpperLegL", "LowerLegL", "FootL" },
}

-- JOINTS ----------------------------------------------------------------------
--
-- Which part connects to which is structure, not tuning, so the topology lives here
-- and only the angles come from Config. Attachment0 is always the proximal part --
-- the one nearer the torso -- which is also what owns the constraint, so a ball
-- socket's cone opens outward along the limb.
--
-- Every joint names the same attachment on both parts except the neck, which the
-- model splits into NeckBottom and NeckTop.

type BallSocketSpec = {
	Name: string,
	Proximal: string,
	ProximalAttachment: string,
	Distal: string,
	DistalAttachment: string,
	Frame: CFrame,
	Limit: number,
}

type HingeSpec = {
	Name: string,
	Proximal: string,
	Distal: string,
	Attachment: string,
	Frame: CFrame,
	Min: number,
	Max: number,
}

local function ballSocketSpec(name: string, proximal: string, distal: string, frame: CFrame, limit: number): BallSocketSpec
	return {
		Name = name,
		Proximal = proximal,
		ProximalAttachment = name,
		Distal = distal,
		DistalAttachment = name,
		Frame = frame,
		Limit = limit,
	}
end

local BALL_SOCKETS: { BallSocketSpec } = {
	{
		Name = "Neck",
		Proximal = "Torso",
		ProximalAttachment = "NeckBottom",
		Distal = "Head",
		DistalAttachment = "NeckTop",
		Frame = CONE_UP,
		Limit = Config.JointLimits.Head.Limit,
	},

	ballSocketSpec("ShoulderR", "Torso", "UpperArmR", CONE_DOWN, Config.JointLimits.Shoulder.Limit),
	ballSocketSpec("ShoulderL", "Torso", "UpperArmL", CONE_DOWN, Config.JointLimits.Shoulder.Limit),

	ballSocketSpec("WristR", "LowerArmR", "HandR", CONE_DOWN, Config.JointLimits.Hand.Limit),
	ballSocketSpec("WristL", "LowerArmL", "HandL", CONE_DOWN, Config.JointLimits.Hand.Limit),

	ballSocketSpec("HipR", "Torso", "UpperLegR", CONE_DOWN, Config.JointLimits.Hip.Limit),
	ballSocketSpec("HipL", "Torso", "UpperLegL", CONE_DOWN, Config.JointLimits.Hip.Limit),

	ballSocketSpec("AnkleR", "LowerLegR", "FootR", CONE_DOWN, Config.JointLimits.Foot.Limit),
	ballSocketSpec("AnkleL", "LowerLegL", "FootL", CONE_DOWN, Config.JointLimits.Foot.Limit),
}

local HINGES: { HingeSpec } = {
	{
		Name = "ElbowR",
		Proximal = "UpperArmR",
		Distal = "LowerArmR",
		Attachment = "ElbowR",
		Frame = HINGE_FORWARD,
		Min = Config.JointLimits.Elbow.Min,
		Max = Config.JointLimits.Elbow.Max,
	},
	{
		Name = "ElbowL",
		Proximal = "UpperArmL",
		Distal = "LowerArmL",
		Attachment = "ElbowL",
		Frame = HINGE_FORWARD,
		Min = Config.JointLimits.Elbow.Min,
		Max = Config.JointLimits.Elbow.Max,
	},
	{
		Name = "KneeR",
		Proximal = "UpperLegR",
		Distal = "LowerLegR",
		Attachment = "KneeR",
		Frame = HINGE_BACKWARD,
		Min = Config.JointLimits.Knee.Min,
		Max = Config.JointLimits.Knee.Max,
	},
	{
		Name = "KneeL",
		Proximal = "UpperLegL",
		Distal = "LowerLegL",
		Attachment = "KneeL",
		Frame = HINGE_BACKWARD,
		Min = Config.JointLimits.Knee.Min,
		Max = Config.JointLimits.Knee.Max,
	},
}

-- Which extremity carries each limb's AlignPosition and grip point.
local LIMB_EXTREMITY: { [LimbId]: string } = {
	ArmR = "HandR",
	ArmL = "HandL",
	LegR = "FootR",
	LegL = "FootL",
}

--------------------------------------------------------------------------------

local ClimberRig = {}

-- Lookups that name what is missing rather than failing later as a nil index. The
-- model is hand-built, so a renamed part is a plausible mistake and a silent one.
local function findPart(model: Model, name: string): BasePart
	local part = model:FindFirstChild(name)
	if part and part:IsA("BasePart") then
		return part
	end
	error(`climber rig template has no BasePart named "{name}"`)
end

local function findAttachment(part: BasePart, name: string): Attachment
	local attachment = part:FindFirstChild(name)
	if attachment and attachment:IsA("Attachment") then
		return attachment
	end
	error(`rig part "{part.Name}" has no Attachment named "{name}"`)
end

-- Sets a constraint frame while leaving the modelled joint position untouched.
local function orient(attachment: Attachment, frame: CFrame)
	attachment.CFrame = CFrame.new(attachment.Position) * frame
end

local function applyPhysicalProperties(model: Model)
	for partName, grade in PART_GRADE do
		findPart(model, partName).CustomPhysicalProperties = PhysicalProperties.new(
			grade.Density * Config.Mass.BaseDensity,
			grade.Friction,
			Config.Mass.Elasticity,
			Config.Mass.FrictionWeight,
			Config.Mass.ElasticityWeight
		)
	end
end

-- Registering is idempotent so a respawned rig can call this again. The collidability
-- matrix is global rather than per-rig, which is fine while there is one rig.
local function applyCollisionGroups(model: Model)
	for groupName, members in GROUP_MEMBERS do
		if not PhysicsService:IsCollisionGroupRegistered(groupName) then
			PhysicsService:RegisterCollisionGroup(groupName)
		end
		PhysicsService:CollisionGroupSetCollidable(groupName, groupName, false)

		for _, partName in members do
			findPart(model, partName).CollisionGroup = groupName
		end
	end
end

local function buildJoints(model: Model)
	for _, spec in BALL_SOCKETS do
		local proximal = findPart(model, spec.Proximal)
		local attachment0 = findAttachment(proximal, spec.ProximalAttachment)
		local attachment1 = findAttachment(findPart(model, spec.Distal), spec.DistalAttachment)

		orient(attachment0, spec.Frame)
		orient(attachment1, spec.Frame)

		-- Prefixed because the constraint is parented to the same part that holds the
		-- attachment it is named after -- the torso ends up owning five of each -- and
		-- a bare name would make FindFirstChild ambiguous.
		local constraint = Instance.new("BallSocketConstraint")
		constraint.Name = `Joint_{spec.Name}`
		constraint.Attachment0 = attachment0
		constraint.Attachment1 = attachment1
		constraint.LimitsEnabled = true
		constraint.UpperAngle = spec.Limit
		constraint.Parent = proximal
	end

	for _, spec in HINGES do
		local proximal = findPart(model, spec.Proximal)
		local attachment0 = findAttachment(proximal, spec.Attachment)
		local attachment1 = findAttachment(findPart(model, spec.Distal), spec.Attachment)

		-- Both frames get the same orientation, which is what puts the hinge's zero
		-- angle at the rig's modelled rest pose.
		orient(attachment0, spec.Frame)
		orient(attachment1, spec.Frame)

		local constraint = Instance.new("HingeConstraint")
		constraint.Name = `Joint_{spec.Name}`
		constraint.Attachment0 = attachment0
		constraint.Attachment1 = attachment1
		constraint.LimitsEnabled = true
		constraint.LowerAngle = spec.Min
		constraint.UpperAngle = spec.Max
		constraint.Parent = proximal
	end
end

-- Mirrors a Config value onto an attribute of the rig model and applies it on change.
-- A running server caches the Config module, so editing the file mid-test does
-- nothing; these attributes are what you actually drag during a playtest.
local function bindTunable(model: Model, name: string, value: number, apply: (number) -> ())
	model:SetAttribute(name, value)
	apply(value)

	model:GetAttributeChangedSignal(name):Connect(function()
		local updated = model:GetAttribute(name)
		if typeof(updated) == "number" then
			apply(updated)
		end
	end)
end

-- Anchored parts are server-simulated by definition, and SetNetworkOwner throws when
-- called on one. Everything that actually simulates gets claimed.
function ClimberRig.ClaimOwnership(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			descendant:SetNetworkOwner(nil)
		end
	end
end

function ClimberRig.Build(): Rig
	local assets = ServerStorage:FindFirstChild("Assets")
	local template = if assets then assets:FindFirstChild(Config.Rig.TemplateName) else nil
	if not template or not template:IsA("Model") then
		error(`no rig template Model at ServerStorage/Assets/{Config.Rig.TemplateName} -- is Rojo syncing assets/climber.rbxm?`)
	end

	local model = template:Clone()
	model.Name = Config.Rig.ModelName

	local torso = findPart(model, "Torso")
	model.PrimaryPart = torso

	applyPhysicalProperties(model)
	applyCollisionGroups(model)

	-- The torso is still held in place in phase 2, as it was in phase 1: the limbs
	-- hang off a fixed body. Letting it fall needs the anchor and respawn system,
	-- which is phase 5.
	torso.Anchored = true

	-- Puts the torso's centre exactly on SpawnPosition, which is what CameraController
	-- and TargetReticle assume while the torso cannot move. Expressed as a translation
	-- of the existing pivot rather than a pivot target, so it lands the torso whatever
	-- the model's pivot happens to be, and so the modelled rotations survive untouched.
	model:PivotTo(model:GetPivot() + (Config.Rig.SpawnPosition - torso.Position))

	buildJoints(model)

	local limbs: { [LimbId]: Limb } = {}
	local aligns: { AlignPosition } = {}

	for limbId, extremityName in LIMB_EXTREMITY do
		local extremity = findPart(model, extremityName)

		-- The model's Grip attachment is the extremity's centre. It is both what
		-- AlignPosition pulls and what a grip's BallSocketConstraint hangs off, so
		-- there is only one, and it carries no constraint frame of its own.
		local gripAttachment = findAttachment(extremity, "Grip")

		-- No IK solver: the extremity chases a point and the limb shape falls out of
		-- the joint limits. Disabled until the player actually reaches.
		local align = Instance.new("AlignPosition")
		align.Name = "Reach"
		align.Mode = Enum.PositionAlignmentMode.OneAttachment
		align.Attachment0 = gripAttachment
		align.RigidityEnabled = false
		align.ReactionForceEnabled = false
		align.Enabled = false
		align.Parent = extremity

		table.insert(aligns, align)

		limbs[limbId] = {
			limbId = limbId,
			extremity = extremity,
			gripAttachment = gripAttachment,
			align = align,
		}
	end

	model.Parent = workspace

	-- One dial per property, applied to all four limbs. Tuning one limb against the
	-- others is not a thing anyone wants to do.
	bindTunable(model, "MaxForce", Config.AlignPosition.MaxForce, function(value)
		for _, align in aligns do
			align.MaxForce = value
		end
	end)
	bindTunable(model, "Responsiveness", Config.AlignPosition.Responsiveness, function(value)
		for _, align in aligns do
			align.Responsiveness = value
		end
	end)
	bindTunable(model, "MaxVelocity", Config.AlignPosition.MaxVelocity, function(value)
		for _, align in aligns do
			align.MaxVelocity = value
		end
	end)

	ClimberRig.ClaimOwnership(model)

	return {
		model = model,
		torso = torso,
		limbs = limbs,
	}
end

return ClimberRig
