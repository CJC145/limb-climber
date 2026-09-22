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

-- Joint angle limits in degrees, from the design doc's rig table except where the
-- playtest overruled it -- see the shoulder and hip below.
--
-- These are unsigned anatomical ranges. Which way a hinge bends is not a tunable --
-- it falls out of which way the hinge axis faces -- so ClimberRig owns the direction
-- and an elbow and a knee both read 0 to ~140 here despite bending opposite ways.
--
-- WHAT A BALL SOCKET LIMIT MEASURES, because the shoulder figure was wrong for
-- exactly this reason. It is a cone half-angle measured from the joint's *rest*
-- direction, which for every limb here is straight down:
--
--     0 deg    limb hanging straight down
--     90 deg   limb horizontal -- out to the side, forward, or across the body
--     180 deg  limb straight up
--
-- It is not a range either side of anything. A limit of 90 does not mean "90 degrees
-- of freedom", it means the limb may reach horizontal and stop dead there.
Config.JointLimits = {
	Head = { Type = "BallSocket", Limit = 45 },

	-- 150, not the doc's 90.
	--
	-- At 90 the arm could reach exactly horizontal and no further, which put the hand
	-- level with its own shoulder on the body's midline and made a cross-body reach
	-- impossible -- the playtest read this as the arm being weak, because a joint
	-- pinned against its limit and a limb with no force behind it look identical from
	-- outside. 150 puts the hand well past the midline and 60 degrees above
	-- horizontal, which is where the interesting holds are.
	--
	-- Anatomically generous rather than accurate. A real shoulder's range depends on
	-- which direction it is travelling in, and a cone has only one number; the cone
	-- has to be cut for the widest direction or it blocks that one.
	Shoulder = { Type = "BallSocket", Limit = 150 },

	Elbow = { Type = "Hinge", Min = 0, Max = 145 },
	Hand = { Type = "BallSocket", Limit = 60 },

	-- 120, not the doc's 75, and wrong in the same way for the same reason. At 75 the
	-- thigh stopped 15 degrees short of horizontal, so a knee could not come up to
	-- chest height and a foot could not be placed on a hold above waist level -- which
	-- is most of climbing.
	--
	-- Lower than the shoulder deliberately, not for anatomy but because the legs carry
	-- the body's weight against the wall and a hip that folds as freely as a shoulder
	-- lets the rig collapse into itself. This is a feel dial, and the first thing to
	-- try if high foot placements are still blocked.
	Hip = { Type = "BallSocket", Limit = 120 },

	Knee = { Type = "Hinge", Min = 0, Max = 140 },
	Foot = { Type = "BallSocket", Limit = 45 },
}

-- AlignPosition, the primary feel dial. The design doc calls MaxForce out as the
-- main thing to tune but gives no starting number. These started as guesses and have
-- had one playtest pass over them, so they are now measured against somebody's hands
-- rather than against nothing -- which is not the same as settled.
--
-- MaxForce is a fraction of the rig's own weight rather than a raw number, and
-- ClimberRig multiplies it by the weight it measures off the 14 parts at build.
--
-- That is a bug fix, not tidiness. At a raw 10000 the aligns could out-pull gravity
-- on the whole climber, so once phase 5 unanchored the torso a limb reaching at the
-- sky flew the entire body. Expressing the dial as a share of the body's own weight
-- is what makes the failure describable at all: the question "can a limb lift the
-- climber" stops being an empirical one about a number nobody can read and becomes
-- arithmetic anyone can check. The bound that matters is below.
--
-- THE GUARANTEE, and what breaks it. Four limbs can reach at once, so the number
-- that actually has to stay under 1.0 is the *total*:
--
--     nothing gripped   4 x MaxForceWeightFraction x FreefallForceScale  =  0.84
--     something gripped 3 x MaxForceWeightFraction                       =  4.2
--
-- Only the first line is a guarantee, and it is the one that matters -- a body with
-- nothing holding on must not be able to fly. The second is deliberately allowed to
-- exceed 1.0: a fourth limb is gripped in that case, the body is hanging off it, and
-- three limbs hauling against that hold is the gripped arm pulling the body up. That
-- is climbing. Capping it would delete the mechanic.
--
-- So if you raise either dial, keep their product under 0.25. It currently sits at
-- 1.4 x 0.15 = 0.21, which leaves room to take the fraction to about 1.66 before the
-- budget is spent and FreefallForceScale has to come down to pay for more.
--
-- NOTE: a running server caches this module, so editing the file mid-playtest does
-- not change anything. ClimberRig mirrors these onto attributes of the rig model so
-- they can be dragged live in the Properties panel; write the value you settle on
-- back into this file.
Config.AlignPosition = {
	-- Fraction of the rig's total weight one limb may pull with.
	--
	-- Raised from 0.8 after the first playtest, where limbs read as weak and slow.
	-- Above 1.0 now, which is fine and is not the guarantee being bent: a single limb
	-- can out-pull the body's weight only in the case where something else is gripped
	-- and the body is hanging off it, which is climbing. The airborne case is the one
	-- that is bounded, and it is bounded below.
	MaxForceWeightFraction = 1.4,

	-- What that fraction is multiplied by while no limb is gripped. "Heavily reduced"
	-- rather than zero: the climber has to be able to reach for its first hold from a
	-- standing start, so this cannot become a gate without deadlocking the spawn.
	--
	-- What it buys is that a reach made in mid-air is weak and flaily -- you can grab
	-- at a passing ledge, but you cannot swim.
	--
	-- Lowered from 0.25 to pay for the fraction above, which is why it looks like a
	-- weakening and is not one. In absolute terms an airborne reach went from
	-- 0.8 x 0.25 = 0.2 of body weight to 1.4 x 0.15 = 0.21, so mid-air flailing is
	-- very slightly stronger than it was. All that moved is the gap between airborne
	-- and gripped, which widened -- which is the point.
	FreefallForceScale = 0.15,

	-- How hard the align converges once it has a force budget to spend. Raised from
	-- 25 in the same pass and for the same complaint: force decides whether a limb
	-- can move, this decides how decisively it commits to the move. Past here it
	-- starts to read as a limb slamming into position and ringing.
	Responsiveness = 45,

	-- Untouched, and deliberately. At 40 studs/s a limb crosses its whole reach
	-- envelope in under a tenth of a second, so this cap is nowhere near binding and
	-- raising it would change nothing about how slow a limb feels.
	MaxVelocity = 40,
}

-- Stamina drain per second for a gripped limb, keyed by how many limbs are gripped
-- in total. The design doc only gives qualitative rates ("very fast"/"fast"/
-- "slow"/"regenerating"), so the shape is the doc's and the magnitudes are not.
--
-- Halved across the board after the first playtest, where stamina ran out faster
-- than a hold could be planned. Every entry scaled by the same factor, so this is a
-- change of timescale and not of shape: one limb is still the emergency, two is
-- still the climbing state, three is still the rest, four still recovers.
--
--     1 limb    10s of hanging before the arm gives out
--     2 limbs   20s
--     3 limbs   50s
--     4 limbs   ~33s to refill from empty
--
-- WATCH THIS. RegenRate below was not halved, because it is not in this table and
-- the complaint was about draining rather than recovering. That means the one ratio
-- this pass did *not* preserve is resting-recovery against drain, which is now twice
-- as generous as it was. If the next playtest says stamina has stopped mattering,
-- that ratio is the first place to look and not these four numbers.
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
		[1] = 10,
		[2] = 5,
		[3] = 2,
		[4] = -3,
	},
	RegenRate = 8,

	-- What a pulling limb pays, as a multiple of its row above. Hauling is work and
	-- hanging is not, so a pull that cost the same as a rest would make pulling the
	-- default state and delete the choice.
	--
	-- ONE WRINKLE, because the four-limb row is negative. Multiplying a regeneration
	-- makes it regenerate faster, which is the opposite of a cost, so a pulling limb's
	-- rate is floored at zero before the multiplier is applied. Pulling on all fours
	-- therefore cancels the rest bonus rather than draining, which is the intended
	-- reading of that row: you can haul from the safest position and it stops being a
	-- recovery while you do.
	--
	-- At 2.0 a pull costs what hanging cost before the last tuning pass -- five seconds
	-- on one arm, ten on two. Guess, but a guess with a shape: the interesting number
	-- is whether a full ascent is cheaper in two big pulls or four small ones.
	PullMultiplier = 2.0,

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

-- Joint tone: the resistance that stops the body being a bag of loose parts.
--
-- Every joint had limits and nothing else, so nothing anywhere in the rig held a
-- pose. Limbs swung until something stopped them and the body read as unresponsive
-- rather than heavy -- the playtest word was "limp". The goal here is tone, not
-- rigidity: the climber should still be floppy, just not boneless.
--
-- TWO NUMBERS BECAUSE THERE ARE TWO MECHANISMS, not because tone is two ideas.
-- Roblox gives a BallSocketConstraint a friction torque and gives a HingeConstraint
-- nothing of the kind, so hinges borrow their actuator instead and hold a target
-- angle softly. Dry friction and a weak servo do not feel the same at equal torque,
-- so one shared number would mean tuning one joint type by making the other wrong.
Config.Joints = {
	-- MaxFrictionTorque on the shoulders, hips, wrists, ankles and neck. Resists
	-- rotation up to this much and then yields, so a limb settles where it is put
	-- and can still be moved.
	--
	-- Wants to sit near the gravity torque on the limb hanging off it: below that
	-- and the joint sags anyway, far above it and the arm is a statue.
	--
	-- Down from 250 after the playtest called it slightly stiff. Deliberately a
	-- third off rather than a halving: the value before this one was a free-swinging
	-- zero, and the useful range is somewhere between the two rather than near
	-- either end.
	BallSocketFriction = 160,

	-- ServoMaxTorque on the idle elbows and knees. Same intent as the friction above
	-- and the same scale, but it is doing more work -- see RestBend.
	--
	-- Has to stay well under what an AlignPosition can generate at the same joint, or
	-- a reach would be fighting the limb's own tone to straighten it. With MaxForce at
	-- 1.4 body weights over a forearm's leverage there are thousands of torque
	-- available against this, so there is a lot of room before that becomes a problem.
	--
	-- Down from 250 alongside the friction above, by the same third and for the same
	-- complaint. Kept equal to it, not because the two mechanisms are interchangeable
	-- -- they are not -- but because nothing yet suggests an elbow wants a different
	-- amount of tone from a shoulder. Split them the moment something does.
	HingeTone = 160,

	-- How fast a relaxed elbow or knee settles toward its rest bend, in radians per
	-- second. This is a limb relaxing, not a limb acting, so it is deliberately
	-- unhurried.
	--
	-- UNITS ARE THE RISK HERE. TargetAngle is degrees and AngularSpeed is radians per
	-- second, which is Roblox being inconsistent rather than a typo. If a released
	-- limb takes an age to sag into its bend, this is the first suspect.
	HingeSettleSpeed = 2,

	-- The rest angle of an elbow or a knee, in degrees, and a fix for a fault flagged
	-- in phase 2 and never addressed: both hinges rested at exactly 0, which is their
	-- hard lower stop. A joint parked on its own limit is a solver pressing against a
	-- wall every frame -- it buzzes, it jitters, and it never quite settles.
	--
	-- A dozen degrees inside the range costs nothing and removes the contact
	-- entirely. It also looks right: a relaxed arm is not a straight arm.
	--
	-- Positive is flexion for both hinges -- the knee's axis is flipped at build for
	-- exactly that reason -- so one value bends an elbow and a knee the way each
	-- actually bends. Zero here restores the old buzzing behaviour, which is a useful
	-- thing to be able to do while working out whether this is the fix.
	RestBend = 12,
}

-- Pulling: the hinge motors on the elbows and knees, and the only way the body goes
-- up. Nothing here comes from the design doc, which had no ascent mechanism at all.
--
-- WHY THIS IS SAFE without a bound of the kind MaxForce needs. A motor applies equal
-- and opposite torque to the two parts of its own joint, so it is internal to the
-- body: with nothing gripped it can only spin a limb against the rest of the rig, and
-- the climber curls up rather than climbing. It moves the body only when a grip is
-- holding one end of the chain to the world, which is the mountain pushing back. No
-- arrangement of these numbers can make a free-floating body rise.
--
-- That is also why nothing here is expressed as a fraction of the rig's weight the
-- way the align force is. The torque a pull needs scales with weight *and* with limb
-- length -- it is roughly body weight times the forearm -- so a weight fraction would
-- not be scale-correct either, and there is no guarantee for it to enforce.
Config.Pull = {
	-- Guess, and the number most likely to be wrong. The scale to reason in: lifting
	-- the body on one arm needs roughly the rig's weight times the forearm's length,
	-- so with a weight in the low thousands and a forearm of a stud or two, this wants
	-- to be thousands rather than tens. Too low and a pull does nothing on a loaded
	-- limb; too high and the climber snaps upward like a mousetrap.
	MotorMaxTorque = 6000,

	-- Radians per second the joint sweeps while pulling. A 145 degree elbow is about
	-- 2.5 radians end to end, so this is a little under a second for a full haul --
	-- deliberate rather than snappy, because a body this heavy arriving instantly
	-- reads as a glitch rather than as strength. Guess.
	AngularVelocity = 3,
}

-- Rolling: torque on the torso about its own forward axis, for righting a sprawled
-- body and for turning over on a ledge. Nothing in the design doc; the climber had
-- no way to reorient itself at all.
--
-- SAFE FOR A DIFFERENT REASON THAN THE PULL. A pull is safe because a joint motor is
-- internal to the body. This is not internal -- it acts on the torso against the
-- world -- but a Torque constraint applies a pure couple, which has no resultant
-- force, so it can only ever spin the body and never move it anywhere. There is no
-- amount of this that lifts a climber.
--
-- What it can do badly is spin. Torque is acceleration, not speed, so a held key in
-- open air keeps adding to the rate rather than settling at one, which is what the
-- scale below is for.
Config.Roll = {
	-- Guess, and the one to expect to move. It has to beat the torque gravity exerts
	-- on a body lying awkwardly across a ledge, so it is larger than the pull's --
	-- that turns one joint against one limb, this turns the whole climber. Too low
	-- and a sprawled body cannot right itself, which is the entire feature; too high
	-- and a tap flips the climber onto its face.
	Torque = 15000,

	-- Multiplied in while the body is airborne: nothing gripped and nothing
	-- underneath. Deliberately the same shape of dial as FreefallForceScale, and
	-- driven by the same freefall test AnchorService already runs, so there is one
	-- notion of "in the air" in this project rather than two that can disagree.
	--
	-- Heavy reduction because unlimited mid-air rolling is a different game. A little
	-- is right -- a falling climber shifting their weight is real -- but a body that
	-- can spin freely in the air stops reading as a body. Guess.
	FreefallScale = 0.15,
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

	-- MaxFrictionTorque on the ball socket a grip creates, which is a different joint
	-- from the body's own and needs its own number. Without it a gripped climber is a
	-- pendulum: the hold is frictionless, so the body swings about it and keeps
	-- swinging, and every grip ends in a wait for the wobble to stop.
	--
	-- Larger than the body's joints because it is resisting the whole climber's weight
	-- on the leverage of a whole torso, not one limb on one segment.
	--
	-- DO NOT RAISE THIS UNTIL IT LOCKS. The design doc picks a ball socket over a weld
	-- specifically so the body can pivot around the hold, and calls that out as what
	-- makes hanging from one hand look right. This is meant to settle the swing, not
	-- delete it -- enough is when a grip stops ringing, not when the body stops moving.
	-- Guess.
	DampingTorque = 800,
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
	PullModifiers: { Enum.KeyCode },
	RollKeys: { Left: Enum.KeyCode, Right: Enum.KeyCode },
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

	-- Held alongside a limb key to pull with that limb instead of reaching with it.
	--
	-- A modifier rather than a key of its own, because pull is per limb and a bare key
	-- could not say which. It also has to be a modifier rather than a second press on
	-- the limb key: holding a limb key *releases* that limb's grip, and a pull needs
	-- the grip it would have thrown away.
	--
	-- Both shifts, so it does not matter which hand is free.
	PullModifiers = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift },

	-- Roll the torso left and right. A and D because they already mean left and right
	-- to everyone who has played anything, and because they sit in the middle of the
	-- block the limb keys bracket -- Q and E above, Z and C below -- so they are
	-- under the same hand without being under the same finger.
	--
	-- Free despite looking taken. WASD is Roblox's default movement, but
	-- CharacterAutoLoads is off and there is no character to move; the camera is
	-- Scriptable and reads the mouse only. Nothing else in this game binds them.
	--
	-- Checked against everything already bound: Q/E/Z/C are the limbs, Shift is the
	-- pull modifier, F toggles third person, Space is the solo-limb reach alias.
	RollKeys = { Left = Enum.KeyCode.A, Right = Enum.KeyCode.D },
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

	-- LimbPull fires on key edges rather than per frame, so this is not a bandwidth
	-- cap -- it is a ceiling on how fast a client may toggle a motor. Well above what
	-- a hand can do to a key and far below what a script can.
	--
	-- Like LimbIntent, only the "pulling" edge is throttled. Dropping a "stopped"
	-- would leave a motor running with nothing able to switch it off.
	LimbPullMaxPerSecond = 20,

	-- RollIntent, same shape and same reasoning as the pull cap: edges rather than a
	-- stream, and only the edges that *start* a roll are throttled. A dropped "stop"
	-- would leave the torso under torque with nothing able to cancel it.
	RollIntentMaxPerSecond = 20,

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
