--!strict
-- One-off generator for the ClimberV2 test rig. Paste into the Studio command bar
-- (Server) and run once; it builds Workspace.ClimberV2, replacing any previous one.
-- Export that model by hand as assets/climber-v2.rbxm. Not synced by Rojo and not
-- required by anything -- it exists so the rig can be regenerated if proportions move.
--
-- Written by script at the human's explicit request, as a recorded exception to the
-- CLAUDE.md handoff rule for the rig. See CLAUDE.md, "Human handoff points".
--
-- A drop-in for assets/climber.rbxm: the same 14 part names and the same 30
-- attachments on the same parts, all with identity rotation, because ClimberRig sets
-- every constraint frame itself and reads nothing but attachment positions.
--
-- Plus one the original does not have: Harness on the Torso, added in phase 6 as the
-- torso end of the rope. It is not a joint, so nothing else meets it. The backup rig
-- lacks it and ToolService falls back to the torso's centre there.
--
-- THE NAMES ARE MIRRORED ON PURPOSE, exactly as in the original. The body faces -Z,
-- so -X is the climber's own left -- and every *R part goes at -X. The HUD labels
-- and comments already account for this; naming the sides "correctly" here would
-- quietly break them.
--
-- No CustomPhysicalProperties. ClimberRig sets them from Config on every build, so
-- anything written here would be overwritten and then go stale.
--
-- Proportions are roughly human at about 6 studs tall, feet at the origin's height.
-- Limbs are about half the width of the original's. Every joint point is shared
-- exactly by the two attachments that meet there, so nothing snaps on the first
-- physics step.

local ORIGIN = Vector3.new(0, 5, 0) -- where the midpoint between the feet sits

local existing = workspace:FindFirstChild("ClimberV2")
if existing then
	existing:Destroy()
end

local model = Instance.new("Model")
model.Name = "ClimberV2"

local SKIN = Color3.fromRGB(255, 176, 0)
local LIMB = Color3.fromRGB(230, 150, 40)

local function makePart(name: string, size: Vector3, centre: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(ORIGIN + centre)
	part.Color = color
	part.Material = Enum.Material.Plastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	part.CanCollide = true
	part.Parent = model
	return part
end

-- Takes the joint's point in model space, so the two attachments that meet at a
-- joint are written from the same number and cannot disagree.
local function attach(part: BasePart, name: string, point: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = (ORIGIN + point) - part.Position
	attachment.Parent = part
end

-- Core -------------------------------------------------------------------------

local NECK = Vector3.new(0, 5.15, 0)

-- Where the rope clips on: the front of the waist, on the torso's -Z face (the body
-- faces -Z), a little above the hip line at the torso's bottom edge (y 3.0). A
-- harness sits there rather than at the centre of mass, so a caught climber hangs
-- slightly back-tipped, the way a real one does. The height is a judgement call --
-- move it here and regenerate, not in the exported model.
local HARNESS = Vector3.new(0, 3.35, -0.35)

local torso = makePart("Torso", Vector3.new(1.3, 2.1, 0.7), Vector3.new(0, 4.05, 0), SKIN)
attach(torso, "NeckBottom", NECK)
attach(torso, "Harness", HARNESS)

local head = makePart("Head", Vector3.new(0.7, 0.85, 0.8), Vector3.new(0, 5.6, 0), SKIN)
attach(head, "NeckTop", NECK)

-- Limbs ------------------------------------------------------------------------

-- -1 is the climber's left. See the header: R goes there.
for side, x in { R = -1, L = 1 } do
	local armX = 0.92 * x
	local shoulder = Vector3.new(armX, 4.85, 0)
	local elbow = Vector3.new(armX, 3.7, 0)
	local wrist = Vector3.new(armX, 2.7, 0)

	attach(torso, "Shoulder" .. side, shoulder)

	local upperArm = makePart("UpperArm" .. side, Vector3.new(0.5, 1.15, 0.6), Vector3.new(armX, 4.275, 0), LIMB)
	attach(upperArm, "Shoulder" .. side, shoulder)
	attach(upperArm, "Elbow" .. side, elbow)

	local lowerArm = makePart("LowerArm" .. side, Vector3.new(0.4, 1.0, 0.4), Vector3.new(armX, 3.2, 0), LIMB)
	attach(lowerArm, "Elbow" .. side, elbow)
	attach(lowerArm, "Wrist" .. side, wrist)

	local handCentre = Vector3.new(armX, 2.425, 0)
	local hand = makePart("Hand" .. side, Vector3.new(0.25, 0.55, 0.45), handCentre, SKIN)
	attach(hand, "Wrist" .. side, wrist)
	attach(hand, "Grip", handCentre)

	local legX = 0.33 * x
	local hip = Vector3.new(legX, 3.0, 0)
	local knee = Vector3.new(legX, 1.65, 0)
	local ankle = Vector3.new(legX, 0.25, 0)

	attach(torso, "Hip" .. side, hip)

	local upperLeg = makePart("UpperLeg" .. side, Vector3.new(0.5, 1.35, 0.7), Vector3.new(legX, 2.325, 0), LIMB)
	attach(upperLeg, "Hip" .. side, hip)
	attach(upperLeg, "Knee" .. side, knee)

	local lowerLeg = makePart("LowerLeg" .. side, Vector3.new(0.45, 1.4, 0.6), Vector3.new(legX, 0.95, 0), LIMB)
	attach(lowerLeg, "Knee" .. side, knee)
	attach(lowerLeg, "Ankle" .. side, ankle)

	-- Toes toward -Z, which is forward. The ankle sits over the heel end.
	local footCentre = Vector3.new(legX, 0.125, -0.2)
	local foot = makePart("Foot" .. side, Vector3.new(0.5, 0.25, 0.9), footCentre, SKIN)
	attach(foot, "Ankle" .. side, ankle)
	attach(foot, "Grip", footCentre)
end

model.PrimaryPart = torso
model.Parent = workspace

print(`ClimberV2 built: {#model:GetChildren()} parts, {#model:GetDescendants() - #model:GetChildren()} attachments`)
