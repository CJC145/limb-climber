--!strict

-- Every tunable value for the climber lives here. See docs/design.md.
-- Values marked "guess" below have no number given in the design doc and are
-- placeholders to be tuned once the relevant phase is playable.

export type SurfaceEntry = {
	BaseGrip: number,
	FailAfterSeconds: number?,
}

export type PartSpec = {
	Size: Vector3,
	Offset: Vector3,
}

local Config = {}

-- Relative density for CustomPhysicalProperties, torso = 1.0 baseline.
Config.Mass = {
	Torso = 1.0,
	Head = 0.4,
	UpperLimb = 0.5,
	LowerLimb = 0.35,
	Extremity = 0.2,

	-- The doc gives ratios only. This multiplier turns them into absolute Roblox
	-- densities (engine default is 0.7). Guess -- tune alongside MaxForce.
	BaseDensity = 1.4,

	-- Guess. Rig parts should not bounce off the wall.
	Elasticity = 0,
	ElasticityWeight = 1,
	FrictionWeight = 1,
}

-- Friction. Design doc gives ranges (extremities 0.8-1.0, torso/upper limbs 0.2-0.3);
-- these starting values are a guess within those ranges, not measured.
Config.Friction = {
	Torso = 0.25,
	UpperLimb = 0.25,
	Extremity = 0.9,
}

-- Joint angle limits in degrees.
Config.JointLimits = {
	Head = { Type = "BallSocket", Limit = 45 },
	Shoulder = { Type = "BallSocket", Limit = 90 },
	Elbow = { Type = "Hinge", Min = 0, Max = 145 },
	Hand = { Type = "BallSocket", Limit = 60 },
	Hip = { Type = "BallSocket", Limit = 75 },
	Knee = { Type = "Hinge", Min = 0, Max = 140 },
	Foot = { Type = "BallSocket", Limit = 45 },
}

-- AlignPosition, the primary feel dial. The design doc calls MaxForce out as the
-- main thing to tune but gives no starting number -- all three are guesses.
--
-- NOTE: a running server caches this module, so editing the file mid-playtest does
-- not change anything. ClimberRig mirrors these onto attributes of the rig model so
-- they can be dragged live in the Properties panel; write the value you settle on
-- back into this file.
Config.AlignPosition = {
	MaxForce = 10000,
	Responsiveness = 25,
	MaxVelocity = 40,
}

-- Stamina drain per second, keyed by how many limbs are currently gripped.
-- The design doc only gives qualitative rates ("very fast"/"fast"/"slow"/
-- "regenerating"); these numbers are guesses to be tuned in phase 5.
Config.Stamina = {
	Max = 100,
	DrainPerLimbsGripped = {
		[1] = 20,
		[2] = 10,
		[3] = 4,
		[4] = 0,
	},
	RegenRate = 8,
}

-- Camera blend timings, in seconds.
Config.Camera = {
	FocusBlendIn = 0.3,
	FocusBlendOut = 0.5,

	-- Phase 1 only: a fixed camera that frames the rig, giving the mouse something
	-- to cast a ray through. Replaced wholesale by the head-cam in phase 4.
	-- Offset is from the rig spawn point, in world space. Guess.
	Phase1Offset = Vector3.new(10, 2, 14),
}

-- Tool use counts / durations.
Config.Tools = {
	IceScrew = { Uses = 1 },
	ClimbingGloves = { Uses = 5, GripMultiplier = 1.5 },
	Chalk = { Uses = 1, RegenMultiplier = 2, DurationSeconds = 30 },
	Piton = { Uses = 1 },
	Rope = { Uses = 1 },
	GrapplingHook = { Uses = 1 },
}

-- Surface base grip strength by tag. Crumbling fail time is a 3-5s range in the
-- doc; the midpoint is used here as a starting guess.
local surfaces: { [string]: SurfaceEntry } = {
	Rock = { BaseGrip = 1.0 },
	Ice = { BaseGrip = 0.0 },
	Metal = { BaseGrip = 0.6 },
	Crumbling = { BaseGrip = 1.0, FailAfterSeconds = 4 },
	Ungrippable = { BaseGrip = 0.0 },
}
Config.Surfaces = surfaces

-- Grip detection and reach.
Config.Grip = {
	-- How far from the extremity's centre a surface may be and still be grippable
	-- on key release. Large enough to forgive near-misses, small enough that you
	-- cannot grip a wall you are visibly not touching. Guess.
	DetectRadius = 1.2,

	-- Ceiling on how far an intent target may be from the torso. Server-side
	-- validation, and the client clamps to it as well. Guess.
	MaxTargetDistance = 14,
}

-- Input. Phase 1 is one player, one key, per the phase 1 gate.
-- The doc's solo-player binding is Q / E / Z / C; Q is the right arm.
Config.Input = {
	LimbKeys = {
		ArmR = Enum.KeyCode.Q,
	},
}

-- Networking.
Config.Net = {
	-- LimbIntent fires every frame a limb is held, so the cap has to sit above the
	-- display rate. Above this the server drops the extra calls.
	LimbIntentMaxPerSecond = 90,

	-- Per-player attribute prefix LimbAssignment publishes ownership through, so a
	-- client knows which keys are its own. Written only by LimbAssignment.
	LimbOwnershipAttributePrefix = "OwnsLimb_",
}

-- Phase 1 rig geometry. This rig is script-built scaffolding and is replaced by the
-- modelled 11-part rig in phase 2 -- proportions here are readable, not anatomical.
-- Offsets are relative to the rig spawn point, which is the torso's centre.
local rigParts: { [string]: PartSpec } = {
	Torso = { Size = Vector3.new(2, 3, 1), Offset = Vector3.new(0, 0, 0) },
	UpperArmR = { Size = Vector3.new(0.8, 1.6, 0.8), Offset = Vector3.new(1, 0.4, 0) },
	LowerArmR = { Size = Vector3.new(0.7, 1.5, 0.7), Offset = Vector3.new(1, -1.15, 0) },
	HandR = { Size = Vector3.new(0.6, 0.6, 0.6), Offset = Vector3.new(1, -2.2, 0) },
}

Config.Rig = {
	ModelName = "Climber",
	SpawnPosition = Vector3.new(0, 20, 0),
	Parts = rigParts,

	-- Joint positions, same frame of reference as the part offsets above. Each sits
	-- exactly on the boundary between the two parts it connects.
	Joints = {
		ShoulderR = Vector3.new(1, 1.2, 0),
		ElbowR = Vector3.new(1, -0.4, 0),
		WristR = Vector3.new(1, -1.9, 0),
	},
}

return Config
