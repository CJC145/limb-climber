--!strict

-- Grip and release, constraint creation, stamina.
--
-- Stamina is phase 5 and is not here yet. What is here is the grip state machine
-- and CanGrip, which every surface and every future tool must route through.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	constraint: BallSocketConstraint?,
	surfaceAttachment: Attachment?,
}

local GripService = {}

local rigModel: Model? = nil
local runtimes: { [LimbId]: LimbRuntime } = {}

-- The one function every grip decision flows through. Surfaces and tools are
-- modifiers passed in here; nothing anywhere else may special-case either.
--
-- `equippedTools` is accepted and unused in phase 1 -- the shared inventory and
-- every tool that would modify a grip are phase 6.
function GripService.CanGrip(limb: LimbId, surfacePart: BasePart, equippedTools: { string }): (boolean, number)
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

local function setState(runtime: LimbRuntime, state: GripState)
	if runtime.state == state then
		return
	end

	runtime.state = state
	Net.LimbState:FireAllClients(runtime.limb.limbId, state)
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

function GripService.GetState(limbId: LimbId): GripState?
	local runtime = runtimes[limbId]
	return runtime and runtime.state or nil
end

function GripService.Bind(rig: ClimberRig.Rig)
	rigModel = rig.model
	runtimes = {}

	for limbId, limb in rig.limbs do
		runtimes[limbId] = {
			limb = limb,
			state = "Free",
			constraint = nil,
			surfaceAttachment = nil,
		}
	end
end

return GripService
