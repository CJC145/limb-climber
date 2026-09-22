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
--
-- Phase 5 unanchors the torso, so this module also owns the other half of that: the
-- rest pose the rig returns to when AnchorService calls a fall. See RESPAWN.

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

	-- Where this limb's reach is measured from: its own root joint on the torso, a
	-- shoulder or a hip. Not the torso's centre -- an arm's envelope is a sphere
	-- around the shoulder, and centring it on the body would let the hand be sent
	-- to points on the far side of the chest that no arm can fold to.
	root: Attachment,

	-- Radius of that sphere, in studs: the limb's measured chain length scaled by
	-- Config.Grip.ReachFraction.
	reach: number,

	-- The elbow or knee this limb pulls with, carrying both of its actuators already
	-- configured: a motor for the pull and a weak servo for the limb's resting tone.
	-- GripService picks between them with ActuatorType and never sets it to None --
	-- an unactuated hinge has no resistance at all, which is the limpness the servo
	-- exists to fix.
	pullHinge: HingeConstraint,
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
-- Decision 4, as refined by the phase 5 playtest: the segments of one limb do not
-- collide with each other, limbs collide with the torso -- except at the segment
-- that attaches to it.
--
-- The exception is the refinement. An upper arm and a shoulder occupy overlapping
-- space by construction, because the joint between them sits inside both; the same
-- goes for a thigh and a hip. Leaving those pairs collidable meant the solver spent
-- every frame pushing two parts out of an overlap the rig's own geometry created,
-- and the practical effect was a wall down the middle of the body: an arm swinging
-- across the chest hit the torso at the shoulder and stopped, which read as the
-- shoulder being stuck. It was.
--
-- Only the top segment is excused. A forearm, a hand, a shin and a foot all still
-- collide with the torso, so the body remains solid everywhere a limb could actually
-- be driven into it, and a hand cannot pass through the chest. The part that is
-- allowed through is the one that was never free to move away from the torso anyway.
--
-- WHY EIGHT LIMB GROUPS AND NOT FOUR. A part belongs to exactly one collision group,
-- and collidability is defined between pairs of groups, so "upper segments ignore the
-- torso" cannot be expressed while an upper segment shares a group with its own
-- forearm. Splitting each limb in two is the smallest arrangement that says all four
-- things at once:
--
--     Upper <-> Lower, same limb     off   segments of one limb do not collide
--     Lower <-> itself               off   forearm against hand, shin against foot
--     Upper <-> core                 off   the refinement above
--     everything else                on    limb against limb, lower against core,
--                                          and every group against the world
--
-- One shared group for all four upper segments would be fewer groups and wrong: it
-- would have to be non-collidable with every lower group to suppress within-limb
-- collision, which would also stop an upper arm colliding with the *other* arm's
-- forearm and quietly delete limb-against-limb.
--
-- Head shares the torso's group. The doc calls it a camera anchor rather than a
-- hitbox, and the neck's two attachments sit 0.15 studs apart, so leaving head-torso
-- collision on would only fight the neck constraint.

local CORE_GROUP = "ClimberCore"

type LimbGroups = { Upper: string, Lower: string }

local LIMB_GROUP: { [LimbId]: LimbGroups } = {
	ArmR = { Upper = "ClimberArmRUpper", Lower = "ClimberArmRLower" },
	ArmL = { Upper = "ClimberArmLUpper", Lower = "ClimberArmLLower" },
	LegR = { Upper = "ClimberLegRUpper", Lower = "ClimberLegRLower" },
	LegL = { Upper = "ClimberLegLUpper", Lower = "ClimberLegLLower" },
}

local GROUP_MEMBERS: { [string]: { string } } = {
	[CORE_GROUP] = { "Torso", "Head" },

	[LIMB_GROUP.ArmR.Upper] = { "UpperArmR" },
	[LIMB_GROUP.ArmR.Lower] = { "LowerArmR", "HandR" },

	[LIMB_GROUP.ArmL.Upper] = { "UpperArmL" },
	[LIMB_GROUP.ArmL.Lower] = { "LowerArmL", "HandL" },

	[LIMB_GROUP.LegR.Upper] = { "UpperLegR" },
	[LIMB_GROUP.LegR.Lower] = { "LowerLegR", "FootR" },

	[LIMB_GROUP.LegL.Upper] = { "UpperLegL" },
	[LIMB_GROUP.LegL.Lower] = { "LowerLegL", "FootL" },
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

-- PULL DIRECTION --------------------------------------------------------------
--
-- Which way a hinge motor drives when the player pulls, as a sign on the configured
-- angular velocity. Derived here rather than configured because it follows from the
-- axis conventions above, and a number in Config would be a second place for those
-- conventions to live and disagree from.
--
-- The derivation, since it is the thing most worth getting wrong quietly:
--
--   Both hinges are limited to [0, ~145] and both rest at 0, because HINGE_BACKWARD
--   flips the knee's axis so its anatomical bend is the positive direction too. So
--   for either joint, a positive angular velocity drives toward the upper limit,
--   which is flexion -- elbow closing, knee folding.
--
--   An arm hauls by flexing: the hand is gripped above, the elbow closes, and the
--   torso is drawn up toward the hold. That is the positive direction.
--
--   A leg pushes by *extending*: the foot is planted below, the knee straightens, and
--   the torso is driven up away from it. That is the negative direction -- back
--   toward the joint's zero.
--
-- The asymmetry is real and not a sign error. An arm pulls its body to its hand; a
-- leg pushes its body off its foot.
--
-- A consequence worth expecting rather than debugging: a straight leg cannot push,
-- because zero is already its lower limit and there is nothing to extend. The knee
-- has to be bent first, by stepping up onto a hold. That is also true of legs.
local PULL_FLEX = 1 -- elbows: haul the torso toward the hand
local PULL_EXTEND = -1 -- knees: drive the torso off the foot

type HingeSpec = {
	Name: string,
	Proximal: string,
	Distal: string,
	Attachment: string,
	Frame: CFrame,
	Min: number,
	Max: number,
	PullDirection: number,
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
		PullDirection = PULL_FLEX,
	},
	{
		Name = "ElbowL",
		Proximal = "UpperArmL",
		Distal = "LowerArmL",
		Attachment = "ElbowL",
		Frame = HINGE_FORWARD,
		Min = Config.JointLimits.Elbow.Min,
		Max = Config.JointLimits.Elbow.Max,
		PullDirection = PULL_FLEX,
	},
	{
		Name = "KneeR",
		Proximal = "UpperLegR",
		Distal = "LowerLegR",
		Attachment = "KneeR",
		Frame = HINGE_BACKWARD,
		Min = Config.JointLimits.Knee.Min,
		Max = Config.JointLimits.Knee.Max,
		PullDirection = PULL_EXTEND,
	},
	{
		Name = "KneeL",
		Proximal = "UpperLegL",
		Distal = "LowerLegL",
		Attachment = "KneeL",
		Frame = HINGE_BACKWARD,
		Min = Config.JointLimits.Knee.Min,
		Max = Config.JointLimits.Knee.Max,
		PullDirection = PULL_EXTEND,
	},
}

-- Which hinge each limb pulls with: the elbow for an arm, the knee for a leg. The
-- shoulders and hips are ball sockets and cannot be motored, which is the whole
-- reason the pull lives at the middle joint of the chain.
local LIMB_HINGE: { [LimbId]: string } = {
	ArmR = "ElbowR",
	ArmL = "ElbowL",
	LegR = "KneeR",
	LegL = "KneeL",
}

-- Which extremity carries each limb's AlignPosition and grip point. Structure
-- rather than tuning, so it lives here with the rest of the rig topology.

local LIMB_EXTREMITY: { [LimbId]: string } = {
	ArmR = "HandR",
	ArmL = "HandL",
	LegR = "FootR",
	LegL = "FootL",
}

-- REACH -----------------------------------------------------------------------
--
-- How far each limb can actually get, measured rather than declared.
--
-- Each chain link names two attachments on the *same* part, so the distance between
-- them is that segment's length in the part's own local space -- a rigid-body fact
-- that does not change with the pose, and one that costs nothing to read. Summed
-- over the three segments it is the limb's full extension from its root joint.
--
-- Measuring beats a Config number here because the model is the authority on the
-- rig's shape. A number would be a second copy of the proportions, and it would go
-- quietly wrong the first time the rig is remodelled -- which is exactly the kind of
-- silent drift that is hard to attribute later.
--
-- The attachment names are the ones the joint table above already uses, which is
-- also what makes this a topology table and not a set of magic strings: if a name
-- here is wrong, the joint that shares it was wrong first and the rig never built.

type Segment = { Part: string, From: string, To: string }

type ReachSpec = {
	-- On the torso, always. Every limb roots there.
	RootAttachment: string,
	Chain: { Segment },
}

local REACH: { [LimbId]: ReachSpec } = {
	ArmR = {
		RootAttachment = "ShoulderR",
		Chain = {
			{ Part = "UpperArmR", From = "ShoulderR", To = "ElbowR" },
			{ Part = "LowerArmR", From = "ElbowR", To = "WristR" },
			{ Part = "HandR", From = "WristR", To = "Grip" },
		},
	},
	ArmL = {
		RootAttachment = "ShoulderL",
		Chain = {
			{ Part = "UpperArmL", From = "ShoulderL", To = "ElbowL" },
			{ Part = "LowerArmL", From = "ElbowL", To = "WristL" },
			{ Part = "HandL", From = "WristL", To = "Grip" },
		},
	},
	LegR = {
		RootAttachment = "HipR",
		Chain = {
			{ Part = "UpperLegR", From = "HipR", To = "KneeR" },
			{ Part = "LowerLegR", From = "KneeR", To = "AnkleR" },
			{ Part = "FootR", From = "AnkleR", To = "Grip" },
		},
	},
	LegL = {
		RootAttachment = "HipL",
		Chain = {
			{ Part = "UpperLegL", From = "HipL", To = "KneeL" },
			{ Part = "LowerLegL", From = "KneeL", To = "AnkleL" },
			{ Part = "FootL", From = "AnkleL", To = "Grip" },
		},
	},
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

		for _, partName in members do
			findPart(model, partName).CollisionGroup = groupName
		end
	end

	-- Self-collision off only where a group holds more than one part that would
	-- otherwise fight. The upper groups hold one part each and need no such rule; the
	-- core's two parts are the head and torso, which the neck constraint would spend
	-- every frame arguing with.
	PhysicsService:CollisionGroupSetCollidable(CORE_GROUP, CORE_GROUP, false)

	for _, groups in LIMB_GROUP do
		-- Forearm against hand, shin against foot.
		PhysicsService:CollisionGroupSetCollidable(groups.Lower, groups.Lower, false)

		-- The rest of "segments of one limb do not collide": this covers upper against
		-- lower and upper against extremity in one rule, because the extremity shares
		-- the lower group.
		PhysicsService:CollisionGroupSetCollidable(groups.Upper, groups.Lower, false)

		-- The refinement. Everything below this segment still hits the torso.
		PhysicsService:CollisionGroupSetCollidable(groups.Upper, CORE_GROUP, false)
	end
end

-- Returns the hinges by spec name, because the limbs need to find their own again to
-- pull with. The ball sockets are not returned: nothing switches one on later.
local function buildJoints(model: Model): { [string]: HingeConstraint }
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

		-- Written out rather than left at the engine default, which is what it already
		-- was. A BallSocketConstraint carries two independent restrictions: the cone,
		-- which UpperAngle sizes, and a twist range about the cone axis. The playtest
		-- that found the shoulder cone too tight had to rule this one out first, and
		-- "it defaults to false" is a worse answer to that question than a line of code
		-- saying so -- especially for a value nobody would think to look for.
		--
		-- False on purpose, not merely by inheritance. Roll about a limb's own long
		-- axis is not something this game constrains: the hand's own ball socket
		-- decides where the grip point ends up, and a forearm that has rotated on the
		-- way there costs nothing and is one less joint fighting the player.
		constraint.TwistLimitsEnabled = false

		-- Tone. Up to this much torque resisting rotation, and then the joint yields,
		-- so a limb holds roughly where it was left without being locked there.
		--
		-- The cone limit says where a joint may not go; this says how willingly it
		-- goes anywhere at all. The rig had the first and nothing of the second, which
		-- is why it read as limp rather than heavy -- every joint was frictionless and
		-- nothing in the body resisted being swung.
		constraint.MaxFrictionTorque = Config.Joints.BallSocketFriction

		constraint.Parent = proximal
	end

	local hinges: { [string]: HingeConstraint } = {}

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

		-- A hinge has two actuators and this rig uses both, for two different jobs.
		-- Every setting for each is written once here; the only thing that changes at
		-- runtime is which of the two is switched on. Limits apply to both, so a
		-- motored elbow stops at 145 rather than folding the forearm through the upper
		-- arm.
		--
		-- Motor: the pull. Drives at a fixed rate with enough torque to lift the body.
		constraint.MotorMaxTorque = Config.Pull.MotorMaxTorque
		constraint.AngularVelocity = Config.Pull.AngularVelocity * spec.PullDirection

		-- Servo: the resting state. Seeks a slight bend, weakly.
		--
		-- THIS REVERSES AN EARLIER DECISION, deliberately. The pull mechanic left
		-- these hinges at ActuatorType.None so they would hang loose, on the reasoning
		-- that an actuator holding a target is an actuator fighting the ragdoll. That
		-- reasoning was sound and the conclusion was wrong: hanging loose *is* the
		-- complaint. A hinge with limits and no actuator has no resistance at all, and
		-- four of them is a body with no muscle tone in its elbows or knees.
		--
		-- A servo is the better half of the trade because it fixes the rest angle at
		-- the same time. A weak motor at zero velocity would hold whatever angle it
		-- drifted to, including zero -- the hard stop the joint buzzes against. A weak
		-- servo holds a chosen angle, so the joint settles a dozen degrees inside its
		-- range and stays there.
		--
		-- Weak is the load-bearing word. At this torque a reach straightens the arm
		-- without noticing the servo; what the servo wins is the argument with nothing
		-- else pulling.
		constraint.ServoMaxTorque = Config.Joints.HingeTone
		constraint.TargetAngle = Config.Joints.RestBend
		constraint.AngularSpeed = Config.Joints.HingeSettleSpeed

		constraint.ActuatorType = Enum.ActuatorType.Servo

		constraint.Parent = proximal
		hinges[spec.Name] = constraint
	end

	return hinges
end

-- FORCE -----------------------------------------------------------------------
--
-- Two things set the aligns' MaxForce now, so neither of them may write it directly.
-- The Studio dial changes the fraction; GripService changes the scale; this module
-- multiplies them by the measured weight and is the only writer.
--
-- Module-level, because there is one climber -- the same reason the respawn pose
-- below is held here rather than threaded through the Rig record.

local aligns: { AlignPosition } = {}

-- Newtons-equivalent: total mass times gravity, in the units AlignPosition.MaxForce
-- is expressed in. Measured once at build, after the densities are applied.
--
-- Read off workspace.Gravity at that moment. Changing gravity mid-session would
-- leave this stale, which is worth knowing and not worth a signal -- nothing in this
-- project changes it.
local rigWeight = 0

local forceFraction = 0
local forceScale = 1

local function applyMaxForce()
	local force = rigWeight * forceFraction * forceScale
	for _, align in aligns do
		align.MaxForce = force
	end
end

-- Weighs the rig by summing its parts. Iterating PART_GRADE rather than the model's
-- descendants so the total counts the 14 parts the design doc specifies and nothing
-- that might later be parented into the model alongside them.
local function measureWeight(model: Model): number
	local mass = 0
	for partName in PART_GRADE do
		mass += findPart(model, partName):GetMass()
	end
	return mass * workspace.Gravity
end

-- Sums a limb's chain in its own local space. See REACH.
local function measureReach(model: Model, spec: ReachSpec): number
	local length = 0

	for _, segment in spec.Chain do
		local part = findPart(model, segment.Part)
		local from = findAttachment(part, segment.From)
		local to = findAttachment(part, segment.To)
		length += (from.Position - to.Position).Magnitude
	end

	return length * Config.Grip.ReachFraction
end

-- ROLL ------------------------------------------------------------------------
--
-- Torque on the torso about its own forward axis, and the same two-input shape as
-- the reach force above: a direction the players are asking for, a scale for whether
-- the body is airborne, and one function that multiplies them.
--
-- WHICH WAY IS LEFT. The model faces -Z, so with +Y up the climber's right hand is
-- at +X. A right-handed rotation about +Z carries +X toward +Y -- the right side
-- rises and the body tips leftward -- so a positive direction is a roll to the left.
--
-- Derived from the facing convention rather than observed, and a sign error here
-- produces a perfectly working mechanic with its controls swapped. If A tips the
-- body the wrong way, negate this and nothing else.
local ROLL_AXIS = Vector3.zAxis

local rollTorque: Torque? = nil
local rollDirection = 0
local rollScale = 1

local function applyRoll()
	local constraint = rollTorque
	if not constraint then
		return
	end

	constraint.Torque = ROLL_AXIS * (rollDirection * Config.Roll.Torque * rollScale)

	-- Disabled rather than left at zero torque. A constraint doing arithmetic on
	-- nothing every frame is a constraint that can still be seen in the explorer
	-- doing something, and the explorer is where this will be debugged.
	constraint.Enabled = rollDirection ~= 0
end

-- The net of what every player is asking for: -1, 0 or +1. Bootstrap sums the
-- roster and clamps, so two players rolling opposite ways cancel and two rolling the
-- same way are not twice as strong as one.
function ClimberRig.SetRoll(direction: number)
	rollDirection = direction
	applyRoll()
end

-- Scaled down while the body is airborne. AnchorService calls this, because the test
-- for "in the air" is the freefall test it already runs for fall detection, and a
-- second copy of that test would be a second thing to keep in step.
function ClimberRig.SetRollTorqueScale(scale: number)
	rollScale = scale
	applyRoll()
end

-- How hard a reach pulls, as a multiple of the configured fraction. GripService
-- calls this when the number of gripped limbs crosses zero in either direction.
--
-- Deliberately a scale and not a gate. A climber with nothing gripped still has to
-- be able to reach for its first hold, so there is no state in which a limb refuses
-- to move -- only one in which it moves weakly.
function ClimberRig.SetReachForceScale(scale: number)
	forceScale = scale
	applyMaxForce()
end

-- Clamps a target to what this limb can physically get to, without moving it off the
-- line the player is pointing along.
--
-- The envelope is the other half of the flying fix and does the real work there. The
-- old clamp was 14 studs from the torso's centre, several times an arm's length, so a
-- target above the head was permanently unreachable and the align chased it at full
-- force for as long as the key was held -- a sustained upward pull on the body with
-- nothing to pull against. Inside the envelope the hand arrives, the error goes to
-- zero, and the force goes with it.
--
-- HOW THE POINT IS BROUGHT INSIDE, which is what the playtest was about. The first
-- version projected the target radially onto the sphere: it took the direction from
-- the root to the target and walked out along it. That is the shortest way in, and it
-- is the wrong way in, because the root is not where the player is looking from. A
-- target off to one side comes back at a sideways angle, so the hand lands somewhere
-- the player did not point and aiming feels like it is being argued with.
--
-- Clamping along the aim ray instead keeps the one thing the player actually chose.
-- The point slides back down the ray toward the eye until it is inside the sphere, so
-- it stays on the line through the crosshair and only its distance changes. Pointing
-- at a hold out of reach now stretches the hand toward that hold rather than toward
-- something next to it.
--
-- The sphere is still centred on the limb's own root and still measured from the rig,
-- and the server still decides. Only the direction of the correction changed.
function ClimberRig.ClampToReach(limb: Limb, aimOrigin: Vector3, target: Vector3): Vector3
	local centre = limb.root.WorldPosition
	local reach = limb.reach

	if (target - centre).Magnitude <= reach then
		return target
	end

	local along = target - aimOrigin
	local rayLength = along.Magnitude
	if rayLength == 0 then
		-- No ray to clamp along, so there is no direction to preserve. Falls back to
		-- the radial projection, which is the best available answer to "somewhere in
		-- the rough direction of that".
		local offset = target - centre
		return if offset.Magnitude == 0 then target else centre + offset.Unit * reach
	end

	local direction = along / rayLength

	-- Where the ray passes closest to the root, and how much room the sphere has left
	-- at that point. Negative room means the ray misses the sphere entirely.
	local closest = direction:Dot(centre - aimOrigin)
	local gap = centre - (aimOrigin + direction * closest)
	local room = reach * reach - gap:Dot(gap)

	-- The span of the ray that lies inside the sphere, trimmed to the part in front of
	-- the origin. Aiming does not reach behind the player's own eye.
	local half = if room > 0 then math.sqrt(room) else 0
	local nearest = math.max(closest - half, 0)
	local furthest = closest + half

	-- Two ways to have nothing to aim at: the ray misses the envelope, or it only
	-- meets it behind the origin. The second is not reachable through the game's own
	-- cameras -- first person sits inside the sphere and third person orbits facing
	-- the body -- but aimOrigin arrives over the wire, and an inverted span would
	-- otherwise hand math.clamp a minimum above its maximum and throw inside a remote
	-- handler.
	if room < 0 or furthest < nearest then
		-- The player is pointing along a line no part of this limb's envelope touches.
		-- The aim cannot be honoured exactly, so the answer is the nearest reachable
		-- point to that line: the sphere's surface directly out from the ray's closest
		-- approach, which keeps the hand as near the aim as the geometry allows.
		local from = aimOrigin + direction * math.max(closest, 0) - centre
		return if from.Magnitude == 0 then centre + Vector3.yAxis * reach else centre + from.Unit * reach
	end

	-- Clamping the target's own distance into that span slides it along the ray by the
	-- least amount that gets it inside -- backwards in the ordinary case of aiming
	-- past a hold, and forwards in the third-person case of aiming at something nearer
	-- the camera than the body is.
	return aimOrigin + direction * math.clamp(rayLength, nearest, furthest)
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

-- RESPAWN ---------------------------------------------------------------------
--
-- The pose the rig returns to, captured once at Build from the modelled rest pose:
-- the torso's rotation, and every part's CFrame relative to the torso.
--
-- Module-level rather than carried on the Rig record, which is how `rigModel` is
-- held in GripService and for the same reason -- there is one climber, and threading
-- its private respawn state through a shared type would put it in front of every
-- module that only wants the limbs.
--
-- Restoring the pose matters. A rig that has fallen is a heap, and translating the
-- heap to the anchor respawns the climber face down in a pile of its own legs. The
-- rest pose is also the one arrangement that satisfies every joint constraint
-- exactly, so reapplying it cannot leave a constraint violated on the first frame.
local spawnRotation = CFrame.identity
local restPose: { [BasePart]: CFrame } = {}

local function captureRestPose(model: Model, torso: BasePart)
	spawnRotation = torso.CFrame.Rotation
	restPose = {}

	local inverse = torso.CFrame:Inverse()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			restPose[descendant] = inverse * descendant.CFrame
		end
	end
end

-- Puts the rig back at `position` in its rest pose, at rest.
--
-- Callers must tear down every grip first. A grip is a BallSocketConstraint to a
-- surface somewhere else on the mountain, and teleporting one end of it across the
-- level is how a physics explosion starts.
--
-- Velocities are zeroed per part rather than once on the torso. Ball sockets and
-- hinges do not weld parts into a shared assembly the way a Motor6D or a weld would,
-- so each of the 14 parts is its own assembly and carries its own velocity -- the
-- same reason ClaimOwnership has to walk all of them.
function ClimberRig.PlaceAt(rig: Rig, position: Vector3)
	local base = CFrame.new(position) * spawnRotation

	for part, relative in restPose do
		part.CFrame = base * relative
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end

	-- Re-applied because a respawn is exactly the moment the engine may hand a part
	-- to a client. Cheap, and the failure it prevents is a silent desync.
	ClimberRig.ClaimOwnership(rig.model)
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

	-- Phase 5 lets the body fall. Phases 1 and 2 held the torso in place so the limbs
	-- had something fixed to hang off; now the whole rig hangs from whatever its limbs
	-- are gripping, and drops when they are gripping nothing.
	--
	-- Written explicitly rather than by deleting the line that set it true, because
	-- the authority on the rig's properties is the saved model and a template that
	-- ever comes back anchored would leave the body hanging in the air with no error
	-- to explain why. This is also what puts the torso in front of ClaimOwnership,
	-- which skips anchored parts.
	torso.Anchored = false

	-- Puts the torso's centre exactly on SpawnPosition. Expressed as a translation of
	-- the existing pivot rather than a pivot target, so it lands the torso whatever
	-- the model's pivot happens to be, and so the modelled rotations survive untouched.
	model:PivotTo(model:GetPivot() + (Config.Rig.SpawnPosition - torso.Position))

	-- After the placement and before anything simulates, which is the only window in
	-- which the modelled pose can still be read off the live parts.
	captureRestPose(model, torso)

	local hinges = buildJoints(model)

	-- Weighed after the densities are applied and before anything is asked to pull
	-- against it: every force below is a multiple of this number.
	rigWeight = measureWeight(model)
	forceScale = 1

	-- The roll torque, and the one attachment in this project the model does not
	-- supply. It is not a joint location and it is not a placement decision: a Torque
	-- constraint applies a pure couple, which acts on the whole assembly regardless of
	-- where its attachment sits, so only the frame's *orientation* matters and the
	-- position is arbitrary. The torso's own origin is the least surprising arbitrary
	-- point available.
	local rollAttachment = Instance.new("Attachment")
	rollAttachment.Name = "RollPoint"
	rollAttachment.CFrame = CFrame.identity
	rollAttachment.Parent = torso

	local torque = Instance.new("Torque")
	torque.Name = "Roll"
	torque.Attachment0 = rollAttachment

	-- Relative to the attachment, so the axis tumbles with the body. In world terms
	-- the climber's forward axis is wherever the climber is currently pointing, and a
	-- sprawled body being righted is exactly the case where those differ most.
	torque.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	torque.Enabled = false
	torque.Parent = torso

	rollTorque = torque
	rollDirection = 0
	rollScale = 1
	applyRoll()

	local limbs: { [LimbId]: Limb } = {}
	aligns = {}

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

		local spec = REACH[limbId]

		limbs[limbId] = {
			limbId = limbId,
			extremity = extremity,
			gripAttachment = gripAttachment,
			align = align,
			root = findAttachment(torso, spec.RootAttachment),
			reach = measureReach(model, spec),
			pullHinge = hinges[LIMB_HINGE[limbId]],
		}
	end

	model.Parent = workspace

	-- One dial per property, applied to all four limbs. Tuning one limb against the
	-- others is not a thing anyone wants to do.
	--
	-- The force dial is the fraction, not the force. Dragging it in Studio reads as
	-- "what share of its own weight may a limb pull with", which is a question with a
	-- meaningful answer either side of 1.0 -- unlike a raw number, where the value
	-- that flies the body and the value that feels good look equally arbitrary. The
	-- multiplication into a real force happens in applyMaxForce.
	bindTunable(model, "MaxForceWeightFraction", Config.AlignPosition.MaxForceWeightFraction, function(value)
		forceFraction = value
		applyMaxForce()
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
