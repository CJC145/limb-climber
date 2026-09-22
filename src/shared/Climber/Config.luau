--!strict

-- Every tunable value for the climber lives here. See docs/design.md.
-- Values marked "guess" below have no number given in the design doc and are
-- placeholders to be tuned once the relevant phase is playable.

local Config = {}

-- Relative density for CustomPhysicalProperties, torso = 1.0 baseline.
Config.Mass = {
	Torso = 1.0,
	Head = 0.4,
	UpperLimb = 0.5,
	LowerLimb = 0.35,
	Extremity = 0.2,
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

-- AlignPosition.MaxForce, the primary feel dial. The design doc calls this out as
-- the main thing to tune but gives no starting number -- this is a guess (untuned).
Config.AlignPosition = {
	MaxForce = 10000,
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
Config.Surfaces = {
	Rock = { BaseGrip = 1.0 },
	Ice = { BaseGrip = 0.0 },
	Metal = { BaseGrip = 0.6 },
	Crumbling = { BaseGrip = 1.0, FailAfterSeconds = 4 },
	Ungrippable = { BaseGrip = 0.0 },
}

return Config
