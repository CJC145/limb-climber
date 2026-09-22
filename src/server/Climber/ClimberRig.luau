--!strict

-- Rig construction and network ownership.
--
-- Phase 1 builds a torso and a single three-segment right arm. The torso is
-- anchored and does not move; the arm hangs off it under gravity. This rig is
-- scaffolding -- phase 2 replaces it with a modelled 11-part rig, so the geometry
-- here is readable rather than anatomical.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

-- Axis conventions for the joint attachments. Neither is a tunable -- both fall
-- out of how Roblox reads constraint attachments -- so they live here rather than
-- in Config.
--
-- A BallSocketConstraint measures its cone limit around Attachment0's X axis, so
-- the X axis has to point along the limb's rest direction (straight down) or the
-- cone opens sideways and the arm is pinned at the edge of its own limit.
local BALL_SOCKET_ORIENTATION = CFrame.Angles(0, 0, -math.pi / 2)

-- A HingeConstraint rotates about its attachments' X axis, positively by the
-- right-hand rule. Facing the X axis along world -X makes a positive angle bend
-- the forearm forward (toward -Z) rather than backward, which is what lets the
-- 0-145 degree range in Config read as an elbow instead of a broken one.
local HINGE_ORIENTATION = CFrame.Angles(0, math.pi, 0)

-- Which density and friction value each part draws from. The doc's friction table
-- has no lower-limb row, so the forearm borrows the upper-limb value -- worth a
-- look if the forearm slides off the wall in a way the hand does not.
local PART_MATERIAL: { [string]: { Density: number, Friction: number } } = {
	Torso = { Density = Config.Mass.Torso, Friction = Config.Friction.Torso },
	UpperArmR = { Density = Config.Mass.UpperLimb, Friction = Config.Friction.UpperLimb },
	LowerArmR = { Density = Config.Mass.LowerLimb, Friction = Config.Friction.UpperLimb },
	HandR = { Density = Config.Mass.Extremity, Friction = Config.Friction.Extremity },
}

local ClimberRig = {}

local function physicalPropertiesFor(partName: string): PhysicalProperties
	local material = PART_MATERIAL[partName]

	return PhysicalProperties.new(
		material.Density * Config.Mass.BaseDensity,
		material.Friction,
		Config.Mass.Elasticity,
		Config.Mass.FrictionWeight,
		Config.Mass.ElasticityWeight
	)
end

local function buildPart(model: Model, partName: string): BasePart
	local spec = Config.Rig.Parts[partName]

	local part = Instance.new("Part")
	part.Name = partName
	part.Size = spec.Size
	part.CFrame = CFrame.new(Config.Rig.SpawnPosition + spec.Offset)
	part.Anchored = false
	part.CanCollide = true
	part.CustomPhysicalProperties = physicalPropertiesFor(partName)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model

	return part
end

-- Places an attachment on `part` at a joint position expressed in rig-spawn space.
-- Every constraint below gets one of these on both of its parts.
local function jointAttachment(part: BasePart, jointOffset: Vector3, orientation: CFrame, name: string): Attachment
	local partOffset = Config.Rig.Parts[part.Name].Offset

	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = CFrame.new(jointOffset - partOffset) * orientation
	attachment.Parent = part

	return attachment
end

local function ballSocket(name: string, parent: BasePart, a0: Attachment, a1: Attachment, limitDegrees: number)
	local constraint = Instance.new("BallSocketConstraint")
	constraint.Name = name
	constraint.Attachment0 = a0
	constraint.Attachment1 = a1
	constraint.LimitsEnabled = true
	constraint.UpperAngle = limitDegrees
	constraint.Parent = parent
end

local function hinge(name: string, parent: BasePart, a0: Attachment, a1: Attachment, minDegrees: number, maxDegrees: number)
	local constraint = Instance.new("HingeConstraint")
	constraint.Name = name
	constraint.Attachment0 = a0
	constraint.Attachment1 = a1
	constraint.LimitsEnabled = true
	constraint.LowerAngle = minDegrees
	constraint.UpperAngle = maxDegrees
	constraint.Parent = parent
end

-- Mirrors a Config value onto an attribute of the rig model and applies it on
-- change. A running server caches the Config module, so editing the file mid-test
-- does nothing; these attributes are what you actually drag during a playtest.
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

-- Anchored parts are server-simulated by definition, and SetNetworkOwner throws
-- when called on one. Everything that actually simulates gets claimed.
function ClimberRig.ClaimOwnership(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			descendant:SetNetworkOwner(nil)
		end
	end
end

function ClimberRig.Build(): Rig
	local model = Instance.new("Model")
	model.Name = Config.Rig.ModelName

	local torso = buildPart(model, "Torso")
	torso.Anchored = true

	local upperArm = buildPart(model, "UpperArmR")
	local lowerArm = buildPart(model, "LowerArmR")
	local hand = buildPart(model, "HandR")

	model.PrimaryPart = torso

	local joints = Config.Rig.Joints

	ballSocket(
		"ShoulderR",
		torso,
		jointAttachment(torso, joints.ShoulderR, BALL_SOCKET_ORIENTATION, "ShoulderR"),
		jointAttachment(upperArm, joints.ShoulderR, BALL_SOCKET_ORIENTATION, "ShoulderR"),
		Config.JointLimits.Shoulder.Limit
	)

	hinge(
		"ElbowR",
		upperArm,
		jointAttachment(upperArm, joints.ElbowR, HINGE_ORIENTATION, "ElbowR"),
		jointAttachment(lowerArm, joints.ElbowR, HINGE_ORIENTATION, "ElbowR"),
		Config.JointLimits.Elbow.Min,
		Config.JointLimits.Elbow.Max
	)

	ballSocket(
		"WristR",
		lowerArm,
		jointAttachment(lowerArm, joints.WristR, BALL_SOCKET_ORIENTATION, "WristR"),
		jointAttachment(hand, joints.WristR, BALL_SOCKET_ORIENTATION, "WristR"),
		Config.JointLimits.Hand.Limit
	)

	-- The grip attachment is the hand's centre. It is both what AlignPosition pulls
	-- and what a grip's BallSocketConstraint hangs off, so there is only one.
	local gripAttachment = Instance.new("Attachment")
	gripAttachment.Name = "Grip"
	gripAttachment.Parent = hand

	-- No IK solver: the hand chases a point and the arm shape falls out of the
	-- joint limits. Disabled until the player actually reaches.
	local align = Instance.new("AlignPosition")
	align.Name = "Reach"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = gripAttachment
	align.RigidityEnabled = false
	align.ReactionForceEnabled = false
	align.Enabled = false
	align.Parent = hand

	model.Parent = workspace

	bindTunable(model, "MaxForce", Config.AlignPosition.MaxForce, function(value)
		align.MaxForce = value
	end)
	bindTunable(model, "Responsiveness", Config.AlignPosition.Responsiveness, function(value)
		align.Responsiveness = value
	end)
	bindTunable(model, "MaxVelocity", Config.AlignPosition.MaxVelocity, function(value)
		align.MaxVelocity = value
	end)

	ClimberRig.ClaimOwnership(model)

	local limbs: { [LimbId]: Limb } = {
		ArmR = {
			limbId = "ArmR",
			extremity = hand,
			gripAttachment = gripAttachment,
			align = align,
		},
	}

	return {
		model = model,
		torso = torso,
		limbs = limbs,
	}
end

return ClimberRig
