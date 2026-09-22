--!strict

-- Checkpoint anchors, fall detection, rig respawn.
--
-- Decision 3: there is no global fall reset and there are no placed checkpoints.
-- The last player-placed anchor is the fallback, and until one is placed the
-- fallback is the start position. That is the whole of the checkpoint system.
--
-- Phase 5 builds every part of that except the placing. SetAnchor exists and nothing
-- calls it: anchors are driven into surfaces by pitons and ropes, which are phase 6
-- tools. What is live now is the consequence of the torso being unanchored -- the
-- body falls, and something has to notice and put it back.
--
-- No damage and no health, per the design doc. The cost of a fall is the height.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Climber.Config)

local ClimberRig = require(script.Parent.ClimberRig)
local GripService = require(script.Parent.GripService)

local AnchorService = {}

local rig: ClimberRig.Rig? = nil

-- The fallback point. Starts at the spawn and is overwritten by each anchor placed,
-- so there is only ever one -- the *last* one, not a list of them.
local anchorPosition = Config.Rig.SpawnPosition

-- How long the torso has been falling continuously with nothing gripped. Reset by a
-- grip, by slowing down, and by a respawn.
local freefallSeconds = 0

-- The roll torque scale last pushed to ClimberRig, so the write happens on the frame
-- the body leaves or reaches the ground rather than on every frame. Mirrors how
-- GripService holds the reach force scale.
local appliedRollScale = 1

local stepConnection: RBXScriptConnection? = nil

-- Moves the fallback point. Phase 6 calls this when a piton is driven or a rope is
-- fixed; nothing calls it yet.
function AnchorService.SetAnchor(position: Vector3)
	anchorPosition = position
end

function AnchorService.GetAnchor(): Vector3
	return anchorPosition
end

-- Order matters and is the reason this is not three lines inline somewhere.
--
-- Grips come down first, because PlaceAt teleports the rig and a live grip is a
-- constraint pinning one hand to a surface the body is about to leave. Stamina is
-- restored last, after the move, so the refilled bars replicate alongside the body
-- rather than a frame ahead of it.
function AnchorService.Respawn()
	local current = rig
	if not current then
		return
	end

	GripService.ReleaseAll()
	ClimberRig.PlaceAt(current, anchorPosition)
	GripService.RestoreStamina()

	freefallSeconds = 0
end

-- Two triggers, neither of which covers the other.
--
-- The timer is the one that usually fires. A player well above their anchor who
-- falls into open air reaches freefall speed within a second, and waiting for them
-- to also pass below the anchor would mean watching the entire descent first --
-- possibly a hundred studs of it.
--
-- The drop distance catches the opposite shape of failure: a slow slide, or a tumble
-- down a slope, that never gets fast enough to read as freefall but still loses real
-- height. It also means landing counts. A fall that ends on a ledge more than
-- RespawnDropDistance below the anchor is still a fall, even though the body is now
-- sitting still.
--
-- A grip beats both. Anything holding on is not falling, whatever the torso is doing.
local function step(deltaTime: number)
	local current = rig
	if not current then
		return
	end

	local torso = current.torso
	local gripped = GripService.GrippedCount() > 0
	local falling = torso.AssemblyLinearVelocity.Y < -Config.Fall.FreefallSpeed

	-- Nothing holding on and nothing underneath. The same two facts the fall timer
	-- below is built from, read once and used twice rather than tested separately --
	-- a body that counts as falling for the respawn and not for the roll, or the
	-- reverse, would be a bug nobody could describe.
	--
	-- "Nothing underneath" is inferred from the descent rather than from contact.
	-- A body sprawled on a ledge with no grip is not moving, so it is not falling, so
	-- it rolls at full strength -- which is the case this mechanic exists for.
	local airborne = not gripped and falling
	local scale = if airborne then Config.Roll.FreefallScale else 1

	if scale ~= appliedRollScale then
		appliedRollScale = scale
		ClimberRig.SetRollTorqueScale(scale)
	end

	if gripped then
		freefallSeconds = 0
		return
	end

	if falling then
		freefallSeconds += deltaTime
	else
		freefallSeconds = 0
	end

	-- Positive when the torso is below the anchor. Negative while the climber is
	-- above it, which is most of a run, and which is exactly when the timer is doing
	-- all the work.
	local dropped = anchorPosition.Y - torso.Position.Y

	if dropped >= Config.Fall.RespawnDropDistance or freefallSeconds >= Config.Fall.MaxFreefallSeconds then
		AnchorService.Respawn()
	end
end

function AnchorService.Bind(boundRig: ClimberRig.Rig)
	rig = boundRig
	anchorPosition = Config.Rig.SpawnPosition
	freefallSeconds = 0

	-- Matches the scale ClimberRig.Build leaves behind, so the first airborne frame
	-- registers as a change.
	appliedRollScale = 1

	if stepConnection then
		stepConnection:Disconnect()
	end
	stepConnection = RunService.Heartbeat:Connect(step)
end

return AnchorService
