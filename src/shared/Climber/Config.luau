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
-- main thing to tune but gives no starting number -- every value here is a guess.
--
-- MaxForce is a fraction of the rig's own weight rather than a raw number, and
-- ClimberRig multiplies it by the weight it measures off the 14 parts at build.
--
-- That is a bug fix, not tidiness. At a raw 10000 the aligns could out-pull gravity
-- on the whole climber, so once phase 5 unanchored the torso a limb reaching at the
-- sky flew the entire body. Expressed as a fraction below 1.0 the value is
-- arithmetically incapable of it: a limb cannot lift a body that weighs more than
-- the force the limb is permitted to apply.
--
-- THE GUARANTEE, and what breaks it. Four limbs can reach at once, so the number
-- that actually has to stay under 1.0 is the *total*:
--
--     nothing gripped   4 x MaxForceWeightFraction x FreefallForceScale  =  0.8
--     something gripped 3 x MaxForceWeightFraction                       =  2.4
--
-- Only the first line is a guarantee, and it is the one that matters -- a body with
-- nothing holding on must not be able to fly. The second is deliberately allowed to
-- exceed 1.0: a fourth limb is gripped in that case, the body is hanging off it, and
-- three limbs hauling against that hold is the gripped arm pulling the body up. That
-- is climbing. Capping it would delete the mechanic.
--
-- So if you raise either dial, keep their product under 0.25.
--
-- NOTE: a running server caches this module, so editing the file mid-playtest does
-- not change anything. ClimberRig mirrors these onto attributes of the rig model so
-- they can be dragged live in the Properties panel; write the value you settle on
-- back into this file.
Config.AlignPosition = {
	-- Fraction of the rig's total weight one limb may pull with. Below 1.0 by
	-- definition -- see above.
	MaxForceWeightFraction = 0.8,

	-- What that fraction is multiplied by while no limb is gripped. "Heavily reduced"
	-- rather than zero: the climber has to be able to reach for its first hold from a
	-- standing start, so this cannot become a gate without deadlocking the spawn.
	--
	-- What it buys is that a reach made in mid-air is weak and flaily -- you can
	-- grab at a passing ledge, but you cannot swim.
	FreefallForceScale = 0.25,

	Responsiveness = 25,
	MaxVelocity = 40,
}

-- Stamina drain per second for a gripped limb, keyed by how many limbs are gripped
-- in total. The design doc only gives qualitative rates ("very fast"/"fast"/
-- "slow"/"regenerating"); every number here is a guess and the whole table expects
-- to be tuned by playing.
--
-- Note the sign on the four-limb row. The doc's fourth row is "regenerating", not
-- "no drain", so it is a negative drain rather than a zero -- which keeps one code
-- path across all four rows instead of special-casing the top one. It is deliberately
-- smaller than RegenRate: hanging on all fours recovers, but not as fast as letting
-- a limb rest.
--
-- There is no [0] row. Nothing drains when nothing is gripped.
Config.Stamina = {
	Max = 100,
	DrainPerLimbsGripped = {
		[1] = 20,
		[2] = 10,
		[3] = 4,
		[4] = -6,
	},
	RegenRate = 8,

	-- A limb below this cannot grip at all. Without it, an exhausted limb re-grips on
	-- the next key release, drains below zero on the following frame and tears the
	-- grip down again -- churning a constraint pair every few frames for as long as
	-- the player keeps trying. It also gives exhaustion a recovery cost rather than
	-- letting the player tap their way back up the wall.
	--
	-- Guess, and a real feel dial: too high and a slip means a long wait, too low and
	-- exhaustion stops meaning anything.
	MinToGrip = 15,
}

-- Falling. Nothing here comes from the design doc, which says only that a fall past
-- the last anchor respawns the rig there; all three numbers are guesses.
--
-- Two triggers, because neither covers the other. In practice the timer is the one
-- that usually fires -- a long drop from well above the anchor reaches freefall
-- speed within a second, and waiting for it to also pass below the anchor would mean
-- watching the whole descent first. The drop distance catches the opposite case: a
-- slow slide or a tumble down a slope that never gets fast enough to count as
-- freefall but still loses real height.
Config.Fall = {
	-- Studs below the anchor at which the rig respawns, regardless of how it got
	-- there. Landing anywhere above this is just a fall you survived -- you carry on
	-- climbing from where you stopped.
	RespawnDropDistance = 25,

	-- Downward speed, in studs per second, above which the torso counts as falling
	-- rather than settling. Set above the speeds a body reaches while shifting its
	-- weight on a hold, so ordinary climbing never starts the timer.
	FreefallSpeed = 12,

	-- How long the torso may fall continuously, with nothing gripped, before the fall
	-- is called. Long enough to survive a drop onto a ledge a little below, short
	-- enough that a fall into open air does not become a long wait.
	MaxFreefallSeconds = 2.5,
}

-- Camera. Only the two blend timings come from the design doc; every other number
-- here is a guess and expects to be tuned by playing.
--
-- The second tuning pass is now due. These were first set against an anchored torso,
-- where the head barely moved; phase 5 unanchored it, so the follow rate and the
-- third-person distance are being asked to do a job they have not yet been judged
-- on -- keeping a view steady over a body that swings, drops and lands.
Config.Camera = {
	-- Radians of rotation per pixel of mouse movement. Roughly a full turn per
	-- 2000 pixels. Guess, and the first thing to try if the view feels wrong.
	MouseSensitivity = 0.003,

	-- The third-person toggle blend. Cutting between two cameras this far apart is
	-- jarring enough to be a bug. Guess.
	ThirdPersonBlend = 0.35,

	-- How fast the camera's position follows the head, per second. Higher is
	-- tighter, so higher means *less* damping. This is the whole of the remaining
	-- stabilisation: the head jerks with the ragdoll and the view must not.
	--
	-- There is no rotation rate any more. Rotation is the mouse, undamped and 1:1 --
	-- a view that lagged the hand moving it would feel broken rather than heavy.
	PositionFollowRate = 14,

	-- How far a tracked part may jump in one frame before the camera stops damping
	-- and simply cuts to it.
	--
	-- Damping exists to absorb ragdoll jitter, which is small. A respawn is not
	-- jitter: it teleports the body to the anchor, and damping that would drag the
	-- view across the whole mountain at the follow rate. Above this distance the
	-- movement cannot have been physical, so there is nothing to smooth.
	--
	-- Guess, but a wide margin rather than a fine one -- well above the studs a body
	-- crosses in a single frame of a fast fall, well below any respawn worth calling.
	SnapDistance = 8,

	-- Where the eye sits relative to the head part. Clearance is measured from the
	-- head's front face rather than its centre, so it stays outside the head
	-- whatever proportions the modelled rig turns out to have.
	EyeClearance = 0.4,
	EyeHeight = 0.2,

	-- Keeps the view out of the straight-up/straight-down singularity, where yaw
	-- stops being meaningful and the view can flip through the pole. Degrees.
	MaxPitch = 80,

	-- Third-person orbit. The camera sits this far back from the pivot along its own
	-- look direction and always looks straight at it, so pitching swings the camera
	-- around the body rather than sliding it up the frame.
	ThirdPersonDistance = 14,

	-- How far above the torso's centre that pivot sits. The torso rather than the
	-- head, because the head is the top of the body and orbiting it rides the whole
	-- frame high; this offset lifts the pivot off the torso's middle to roughly
	-- chest or shoulder height. Guess, and a feel dial -- expect to tune it by eye.
	ThirdPersonOrbitHeight = 1,

	-- A setting, not a mode: this latches until pressed again. Free of the limb
	-- keys (Q/E/Z/C) and of Space.
	ToggleKey = Enum.KeyCode.F,

	-- Where the camera sits for the few frames before the rig replicates to the
	-- client. Offset from the rig spawn point, in world space.
	--
	-- This is the last use of SpawnPosition in this module and it is a bootstrap
	-- only -- the head-cam itself reads the live Head part and never reads Config
	-- for position again. Without it the camera sits at the origin until the rig
	-- arrives.
	BootstrapOffset = Vector3.new(10, 2, 14),
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

	-- How far a player may point, which is not the same thing as how far a limb can
	-- go. This is the aim ray's range only: it decides how distant a hold you can put
	-- the reticle on, and the reach envelope below decides what the limb does about
	-- it. Guess.
	MaxTargetDistance = 14,

	-- Fraction of a limb's measured chain length that the limb may actually be sent
	-- to. ClimberRig measures the chain off the model -- root joint to elbow or knee,
	-- to wrist or ankle, to the grip point -- so the envelope is the rig's real
	-- geometry and not a number anyone has to keep in sync with it.
	--
	-- Under 1.0 on purpose. At exactly 1.0 the target sits at full extension, which
	-- is only reachable with a perfectly straight limb, so the align never quite
	-- arrives and keeps pulling at maximum force forever -- which is the flying bug
	-- in miniature. A little slack means the hand gets there and the force falls to
	-- zero on its own, which is what makes a reach settle instead of straining.
	ReachFraction = 0.95,
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

	-- LimbState carries stamina, which changes every frame, so the server cannot fire
	-- it per frame the way the client fires intent. This is the rate the server
	-- broadcasts all four limbs at. A grip state *change* is fired immediately and is
	-- not subject to this -- the cap exists for the continuous number, not the edges.
	--
	-- Fast enough that a draining bar reads as draining rather than stepping, slow
	-- enough that four limbs times however many clients stays negligible. Broadcast
	-- unconditionally rather than on change, which is what a client that joined
	-- mid-climb reads its opening state from.
	LimbStateMaxPerSecond = 10,

	-- Per-player attribute prefix LimbAssignment publishes ownership through, so a
	-- client knows which keys are its own. Written only by LimbAssignment.
	LimbOwnershipAttributePrefix = "OwnsLimb_",
}

-- Rig geometry is no longer described here. Phase 1's script-built scaffolding has
-- been replaced by the modelled rig in assets/climber.rbxm, which is the authority
-- on part sizes, part positions and attachment positions. Nothing in code writes
-- them, so there is nothing here to tune.
--
Config.Rig = {
	ModelName = "Climber",
	SpawnPosition = Vector3.new(0, 20, 0),

	-- Name of the rig template under ServerStorage/Assets, as default.project.json
	-- mounts it. ClimberRig clones this; the clone is renamed to ModelName.
	TemplateName = "ClimberRig",
}

return Config
