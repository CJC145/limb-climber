--!strict

-- Shared type definitions. Phase 1 only defines what phase 1 uses; limb ids for
-- limbs that do not exist yet are deliberately absent.

export type LimbId = "ArmR"

export type GripState = "Free" | "Reaching" | "Gripped"

-- Client -> server. Fires every frame a limb is active, so keep it small.
export type LimbIntent = {
	limbId: LimbId,
	targetPosition: Vector3,
	isHeld: boolean,
}

-- Server -> client. The design doc also lists `stamina` on this payload; stamina
-- is phase 5 and is not included here until it exists.
export type LimbState = {
	limbId: LimbId,
	gripState: GripState,
}

return {}
