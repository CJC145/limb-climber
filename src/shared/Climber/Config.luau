--!strict

-- Every tunable value for the climber lives here. See docs/design.md.
-- Values marked "guess" below have no number given in the design doc and are
-- placeholders to be tuned once the relevant phase is playable.

local Types = require(script.Parent.Types)

type LimbId = Types.LimbId

export type SurfaceEntry = {
	BaseGrip: number,
	FailAfterSeconds: number?,
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
--
-- The doc's friction table has no head or lower-limb row. Both values below are
-- therefore guesses on top of guesses: the head borrows the torso value because it
-- is a camera anchor rather than a climbing surface, and the lower limb borrows the
-- upper-limb value. Worth a look if a forearm or shin sticks to a wall in a way the
-- hand or foot does not.
Config.Friction = {
	Torso = 0.25,
	Head = 0.25,
	UpperLimb = 0.25,
	LowerLimb = 0.25,
	Extremity = 0.9,
}

-- Joint angle limits in degrees, straight from the design doc's rig table.
--
-- These are unsigned anatomical ranges. Which way a hinge bends is not a tunable --
-- it falls out of which way the hinge axis faces -- so ClimberRig owns the direction
-- and an elbow and a knee both read 0 to ~140 here despite bending opposite ways.
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

-- Input. The doc's solo-player binding is Q / E / Z / C.
--
-- Which key goes to which limb is fixed by the doc's two-player split, "Q + Z, then
-- E + C", described as left side / right side: Q and Z have to be the same side of
-- the body, not the same row of the keyboard. Q is the right arm, so Q/Z are the
-- right side and E/C the left. Phase 3 can then split a session without rebinding.
-- Annotated through a named type rather than left to inference. Without it the
-- string literals below are inferred as plain `string`, and every consumer that
-- wants a LimbId out of LimbOrder has to cast to get one.
export type InputConfig = {
	LimbKeys: { [LimbId]: Enum.KeyCode },
	LimbOrder: { LimbId },
	SoloLimbKey: Enum.KeyCode,
}

local input: InputConfig = {
	LimbKeys = {
		ArmR = Enum.KeyCode.Q,
		LegR = Enum.KeyCode.Z,
		ArmL = Enum.KeyCode.E,
		LegL = Enum.KeyCode.C,
	},

	-- A stable order for the four limbs. Shared because two places have to walk them
	-- identically every time: the HUD's ownership list, and the server's orphan
	-- reassignment, which would otherwise hand out limbs in Luau's table order and
	-- produce a different split on each disconnect.
	LimbOrder = { "ArmR", "ArmL", "LegR", "LegL" },

	-- The doc's four-player row gives Space as the per-player key. It is an alias
	-- rather than a rebind: it resolves to whichever single limb the presser owns,
	-- and does nothing at all for anyone holding two or more.
	SoloLimbKey = Enum.KeyCode.Space,
}

Config.Input = input

-- Session lifecycle.
Config.Session = {
	-- There is no lobby, so the run starts on a timer: this long after the first
	-- player joins, everyone present is assigned limbs and the session locks.
	-- Long enough for a second client to finish loading into a playtest, short
	-- enough that a solo player is not left waiting on nobody.
	LobbyGraceSeconds = 10,
}

-- Networking.
Config.Net = {
	-- LimbIntent fires every frame a limb is held, so the cap has to sit above the
	-- display rate. Above this the server drops the extra calls.
	--
	-- Counted per limb, not per player: one player can hold all four limbs at once,
	-- and a shared budget would have them starve each other. A player's ceiling is
	-- therefore this times the number of limbs they own.
	LimbIntentMaxPerSecond = 90,

	-- Per-player attribute prefix LimbAssignment publishes ownership through, so a
	-- client knows which keys are its own. Written only by LimbAssignment.
	LimbOwnershipAttributePrefix = "OwnsLimb_",
}

-- Rig geometry is no longer described here. Phase 1's script-built scaffolding has
-- been replaced by the modelled rig in assets/climber.rbxm, which is the authority
-- on part sizes, part positions and attachment positions. Nothing in code writes
-- them, so there is nothing here to tune.
Config.Rig = {
	ModelName = "Climber",
	SpawnPosition = Vector3.new(0, 20, 0),

	-- Name of the rig template under ServerStorage/Assets, as default.project.json
	-- mounts it. ClimberRig clones this; the clone is renamed to ModelName.
	TemplateName = "ClimberRig",
}

return Config
