--!strict

-- Shared type definitions. Phase 2 has the full four-limb rig, so all four limb
-- ids exist; nothing beyond them does.
--
-- Phase 5 completes LimbState: stamina exists now, so the payload matches the design
-- doc's table in full.

export type LimbId = "ArmR" | "ArmL" | "LegR" | "LegL"

export type GripState = "Free" | "Reaching" | "Gripped"

-- Client -> server. Fires every frame a limb is active, so keep it small.
export type LimbIntent = {
	limbId: LimbId,
	targetPosition: Vector3,
	isHeld: boolean,
}

-- Server -> client. Absolute stamina rather than a fraction: Config.Stamina.Max is
-- shared, so a client that wants a 0..1 bar can divide, and a client that wants the
-- number has it. Sending a fraction would throw away which of the two the reader
-- gets to choose.
export type LimbState = {
	limbId: LimbId,
	gripState: GripState,
	stamina: number,
}

return {}
