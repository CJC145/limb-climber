--!strict

-- Grip and release, constraint creation, stamina.
--
-- Phase 5 adds stamina to the grip state machine already here. The two are one
-- system rather than two: stamina is what a grip costs, and exhaustion is one of the
-- two edges out of Gripped in the design doc's state diagram -- the other being the
-- player pressing the key.
--
-- The drain rate is keyed by how many limbs are gripped *in total*, not by anything
-- about the limb paying it. That is the whole of the design doc's pacing mechanic:
-- hanging by one hand is expensive because there is one hand, and the three-points-
-- of-contact rule emerges from the arithmetic rather than from being taught.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Climber.Config)
local Net = require(ReplicatedStorage.Climber.Net)
local Types = require(ReplicatedStorage.Climber.Types)

local SurfaceConfig = require(script.Parent.SurfaceConfig)
local ClimberRig = require(script.Parent.ClimberRig)

type LimbId = Types.LimbId
type GripState = Types.GripState

type LimbRuntime = {
	limb: ClimberRig.Limb,
	state: GripState,
	stamina: number,

	-- What the owning player is asking for, which is not the same as what the motor
	-- is doing. A pull only drives while the limb is also Gripped; this stays true
	-- through an exhaustion or a fall and takes effect again when the limb next takes
	-- a hold, because the player is still holding the key.
	pulling: boolean,

	constraint: BallSocketConstraint?,
	surfaceAttachment: Attachment?,
}

local GripService = {}

local rigModel: Model? = nil
local runtimes: { [LimbId]: LimbRuntime } = {}

-- Heartbeat is connected in Bind and held so a rebind cannot leave two of them
-- running and drain every limb at twice the configured rate.
local stepConnection: RBXScriptConnection? = nil

-- The one function every grip decision flows through. Surfaces and tools are
-- modifiers passed in here; nothing anywhere else may special-case either.
--
-- Stamina is checked here too, and deliberately not through a new argument: it is
-- per-limb state this module already owns, so `limb` is enough to look it up. The
-- signature in the design doc stays as written and the invariant holds -- there is
-- still exactly one place that decides whether a grip may happen.
--
-- `equippedTools` is accepted and unused until phase 6 brings the shared inventory
-- and the tools that would modify a grip.
function GripService.CanGrip(limb: LimbId, surfacePart: BasePart, equippedTools: { string }): (boolean, number)
	-- An exhausted limb cannot grip until it has recovered past the threshold. Without
	-- this, a limb at zero re-grips on the next key release and exhausts again on the
	-- following frame, churning a constraint pair for as long as the player keeps
	-- pressing -- and exhaustion would cost nothing but a tap.
	local runtime = runtimes[limb]
	if runtime and runtime.stamina < Config.Stamina.MinToGrip then
		return false, 0
	end

	local surface = SurfaceConfig.GetProperties(surfacePart)
	if not surface then
		return false, 0
	end

	-- Gripping an unanchored part means fighting over network ownership of whatever
	-- it is attached to. Forbidden until it is designed for deliberately.
	if not surfacePart.Anchored then
		return false, 0
	end

	local strength = surface.BaseGrip
	if strength <= 0 then
		return false, 0
	end

	return true, strength
end

local function broadcast(runtime: LimbRuntime)
	Net.LimbState:FireAllClients(runtime.limb.limbId, runtime.state, runtime.stamina)
end

-- Drives the hinge motor when, and only when, the limb is both gripped and being
-- pulled. Everything that can change either of those two facts routes through here.
--
-- The grip is what makes a pull mean anything. Motor torque is internal to the body,
-- so an ungripped limb that pulls has nothing to push against and simply curls up on
-- itself; the climber cannot lift itself by its own elbows any more than a person can
-- lift themselves by their own belt. Gating on Gripped is therefore not a safety rule
-- -- it is just declining to run a motor that could only produce a twitch.
local function applyPull(runtime: LimbRuntime)
	local driving = runtime.pulling and runtime.state == "Gripped"

	runtime.limb.pullHinge.ActuatorType = if driving
		then Enum.ActuatorType.Motor
		else Enum.ActuatorType.None
end

-- A grip state change is an edge and goes out the moment it happens, unthrottled.
-- The rate cap in Config.Net applies to the continuous stamina stream only: a HUD
-- that showed a reach a tenth of a second late would be a worse limb-intent
-- indicator than one that showed nothing.
local function setState(runtime: LimbRuntime, state: GripState)
	if runtime.state == state then
		return
	end

	runtime.state = state
	broadcast(runtime)

	-- Every route out of Gripped passes through here -- the player letting go,
	-- stamina running out, a fall being called -- so the motor is switched off by
	-- the same line whichever it was, and no caller has to remember to.
	applyPull(runtime)
end

-- Tears down a grip completely. Criterion 8: nothing may survive a release.
local function releaseGrip(runtime: LimbRuntime)
	if runtime.constraint then
		runtime.constraint:Destroy()
		runtime.constraint = nil
	end
	if runtime.surfaceAttachment then
		runtime.surfaceAttachment:Destroy()
		runtime.surfaceAttachment = nil
	end
end

-- Finds the nearest grippable surface the extremity is actually touching. The grip
-- forms where the hand is; the hand is never moved to meet a surface.
local function findSurface(runtime: LimbRuntime): BasePart?
	local model = rigModel
	if not model then
		return nil
	end

	local extremity = runtime.limb.extremity

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }

	local candidates = workspace:GetPartBoundsInRadius(extremity.Position, Config.Grip.DetectRadius, params)

	local best: BasePart? = nil
	local bestDistance = math.huge

	for _, candidate in candidates do
		if candidate:IsA("BasePart") and GripService.CanGrip(runtime.limb.limbId, candidate, {}) then
			local closest = candidate:GetClosestPointOnSurface(extremity.Position)
			local distance = (closest - extremity.Position).Magnitude
			if distance < bestDistance then
				best = candidate
				bestDistance = distance
			end
		end
	end

	return best
end

local function attemptGrip(runtime: LimbRuntime): boolean
	local surfacePart = findSurface(runtime)
	if not surfacePart then
		return false
	end

	local extremity = runtime.limb.extremity

	local surfaceAttachment = Instance.new("Attachment")
	surfaceAttachment.Name = "GripPoint_" .. runtime.limb.limbId
	surfaceAttachment.Parent = surfacePart
	surfaceAttachment.WorldCFrame = CFrame.new(extremity.Position)

	-- A ball socket, never a weld: the body has to be able to pivot around the
	-- grip point, which is what makes hanging off one hand look right.
	local constraint = Instance.new("BallSocketConstraint")
	constraint.Name = "Grip_" .. runtime.limb.limbId
	constraint.Attachment0 = runtime.limb.gripAttachment
	constraint.Attachment1 = surfaceAttachment
	constraint.LimitsEnabled = false
	constraint.Parent = extremity

	runtime.surfaceAttachment = surfaceAttachment
	runtime.constraint = constraint

	return true
end

-- Hold the key to release and aim; release the key to grip. Holding is the active,
-- tiring state, so letting go of the keyboard leaves you gripped rather than falling.
function GripService.SetIntent(limbId: LimbId, targetPosition: Vector3, isHeld: boolean)
	local runtime = runtimes[limbId]
	if not runtime then
		return
	end

	if isHeld then
		releaseGrip(runtime)
		runtime.limb.align.Position = targetPosition
		runtime.limb.align.Enabled = true
		setState(runtime, "Reaching")
		return
	end

	if runtime.state ~= "Reaching" then
		return
	end

	runtime.limb.align.Enabled = false

	if attemptGrip(runtime) then
		setState(runtime, "Gripped")
	else
		setState(runtime, "Free")
	end
end

-- Ends a reach that nobody is going to finish. A player who disconnects mid-hold
-- leaves their limb in Reaching with the align enabled and pulling at a target no
-- release will ever clear, so reassignment calls this on every orphan.
--
-- Deliberately not a grip attempt: a disconnect must not hand out a free hold.
function GripService.AbandonReach(limbId: LimbId)
	local runtime = runtimes[limbId]
	if not runtime or runtime.state ~= "Reaching" then
		return
	end

	-- No releaseGrip here -- entering Reaching already tore the old grip down.
	runtime.limb.align.Enabled = false
	setState(runtime, "Free")
end

-- STAMINA ---------------------------------------------------------------------

local BROADCAST_INTERVAL = 1 / Config.Net.LimbStateMaxPerSecond
local broadcastCountdown = 0

-- The reach force scale currently pushed to ClimberRig, so the write happens on the
-- frame the gripped count crosses zero rather than on every frame.
--
-- Full strength once anything is holding on; heavily reduced while nothing is. The
-- reason is the flying bug: with the torso unanchored and no hold to pull against,
-- four aligns at full force had nothing to move except the body. Weakened in the air
-- they can still grab at a passing ledge but cannot swim.
--
-- Not a gate, deliberately. A climber standing at the spawn with nothing gripped has
-- to be able to reach for its first hold, and "must be gripped to reach" would leave
-- it unable to ever start.
local appliedForceScale = 1

local function grippedCount(): number
	local count = 0
	for _, runtime in runtimes do
		if runtime.state == "Gripped" then
			count += 1
		end
	end
	return count
end

local function step(deltaTime: number)
	local gripped = grippedCount()

	-- Nil at zero, and correctly so: the table has no row for "nothing gripped"
	-- because nothing is paying. The value is only read by gripped limbs, of which
	-- there are none.
	local drain = Config.Stamina.DrainPerLimbsGripped[gripped] or 0

	for _, runtime in runtimes do
		local rate
		if runtime.state ~= "Gripped" then
			rate = Config.Stamina.RegenRate
		else
			-- Drain is stated as a positive cost in Config, so it subtracts. The
			-- four-limb row is negative and therefore adds, which is the doc's
			-- "regenerating".
			local cost = drain

			-- Hauling costs more than hanging. Floored at zero before the multiplier
			-- because the four-limb row is a regeneration, and doubling a regeneration
			-- would make pulling on all fours recover *faster* than resting there --
			-- the opposite of a cost. Floored, it cancels the rest bonus instead,
			-- which is the right reading: you can haul from the safest position, and
			-- it stops being a rest while you do.
			--
			-- Per limb, not per body. A limb that is gripped but not pulling pays its
			-- ordinary rate while the one next to it pays double.
			if runtime.pulling then
				cost = math.max(cost, 0) * Config.Stamina.PullMultiplier
			end

			rate = -cost
		end

		runtime.stamina = math.clamp(runtime.stamina + rate * deltaTime, 0, Config.Stamina.Max)
	end

	-- Exhaustion resolves in a second pass so that every limb drains against the same
	-- gripped count. Releasing inside the loop above would make the cost of the frame
	-- depend on the order Luau happened to walk the table -- the second limb to be
	-- visited would pay a cheaper rate than the first because the first had just let
	-- go, and which limb that was would vary between runs.
	for _, runtime in runtimes do
		if runtime.state == "Gripped" and runtime.stamina <= 0 then
			releaseGrip(runtime)
			setState(runtime, "Free")
		end
	end

	-- Counted again rather than reusing `gripped`, because the pass above may have
	-- just exhausted the last hold. A body that has this instant lost its grip is
	-- airborne, and should not spend a frame still pulling as though it were not.
	local scale = if grippedCount() > 0 then 1 else Config.AlignPosition.FreefallForceScale
	if scale ~= appliedForceScale then
		appliedForceScale = scale
		ClimberRig.SetReachForceScale(scale)
	end

	broadcastCountdown -= deltaTime
	if broadcastCountdown <= 0 then
		broadcastCountdown = BROADCAST_INTERVAL
		for _, runtime in runtimes do
			broadcast(runtime)
		end
	end
end

--------------------------------------------------------------------------------

function GripService.GetState(limbId: LimbId): GripState?
	local runtime = runtimes[limbId]
	return runtime and runtime.state or nil
end

-- Records that the owning player is holding the pull input, and engages the motor if
-- the limb is in a position to use it.
--
-- Held rather than acted on once: the player keeps the key down and the joint keeps
-- driving. Nothing here checks whether pulling is sensible, because there is no way
-- for it not to be -- the worst an ungripped pull can do is curl the limb.
function GripService.SetPull(limbId: LimbId, pulling: boolean)
	local runtime = runtimes[limbId]
	if not runtime or runtime.pulling == pulling then
		return
	end

	runtime.pulling = pulling
	applyPull(runtime)
end

-- How many limbs are bearing load. AnchorService asks, because a body with nothing
-- gripped is the precondition for a fall.
function GripService.GrippedCount(): number
	return grippedCount()
end

-- Settles every limb to Free with nothing attached to it. Called before a respawn
-- moves the rig: a grip is a constraint to a surface elsewhere on the mountain, and
-- teleporting one end of one across the level is how a physics explosion starts.
--
-- Unlike AbandonReach this covers gripped limbs too, and unlike a release it is not
-- a grip attempt -- a fall does not end in a hold.
function GripService.ReleaseAll()
	for _, runtime in runtimes do
		releaseGrip(runtime)
		runtime.limb.align.Enabled = false

		-- Cleared rather than left standing. A respawn is a hard reset of the body,
		-- and a player still holding Shift from before the fall should not find their
		-- arm hauling the instant it takes its next hold, several seconds and one
		-- teleport later. They press again; the key is still under their finger.
		runtime.pulling = false

		setState(runtime, "Free")

		-- setState only fires when the state actually changed, and a limb that was
		-- already Free would not have had its motor stopped by the line above.
		applyPull(runtime)
	end
end

-- The other half of a respawn, per the design doc: the rig comes back at the anchor
-- "with stamina restored". Broadcast immediately rather than left to the next tick,
-- so the bars refill on the same frame the body reappears.
function GripService.RestoreStamina()
	for _, runtime in runtimes do
		runtime.stamina = Config.Stamina.Max
		broadcast(runtime)
	end
end

function GripService.Bind(rig: ClimberRig.Rig)
	rigModel = rig.model
	runtimes = {}

	for limbId, limb in rig.limbs do
		runtimes[limbId] = {
			limb = limb,
			state = "Free",
			stamina = Config.Stamina.Max,
			pulling = false,
			constraint = nil,
			surfaceAttachment = nil,
		}

		-- Matches the ActuatorType ClimberRig.Build leaves the hinge at, so the record
		-- and the constraint agree from the first frame.
		limb.pullHinge.ActuatorType = Enum.ActuatorType.None
	end

	if stepConnection then
		stepConnection:Disconnect()
	end

	broadcastCountdown = 0

	-- Matches the scale ClimberRig.Build leaves behind, so the first heartbeat sees a
	-- real change and drops the rig to its airborne force rather than believing it
	-- has already done so.
	appliedForceScale = 1

	stepConnection = RunService.Heartbeat:Connect(step)
end

return GripService
