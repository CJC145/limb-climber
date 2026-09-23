--!strict

-- Shared type definitions. Phase 2 has the full four-limb rig, so all four limb
-- ids exist; nothing beyond them does.
--
-- Phase 5 completes LimbState: stamina exists now, so the payload matches the design
-- doc's table in full.

export type LimbId = "ArmR" | "ArmL" | "LegR" | "LegL"

export type GripState = "Free" | "Reaching" | "Gripped"

-- Client -> server. Fires every frame a limb is active, so keep it small.
--
-- `aimOrigin` is a second Vector3 the design doc's payload table does not list, and
-- it is not a convenience. The server clamps the target into the limb's reach, and
-- doing that *along the aim ray* rather than radially is what keeps the clamped point
-- on the line the player pointed down -- which needs the line, and the line is the
-- camera's eye, which only the client knows. Sending the point without it leaves the
-- server able to say how far but not which way.
--
-- It grants a client nothing. Every point the clamp can return is inside that limb's
-- own envelope, so the worst a forged origin can do is pick a reachable target, which
-- is what the honest field already does.
export type LimbIntent = {
	limbId: LimbId,
	targetPosition: Vector3,
	aimOrigin: Vector3,
	isHeld: boolean,
}

-- Client -> server. Two of these per pull: one on the key down, one on the key up.
--
-- A held state sent as edges rather than as a per-frame stream, because a motor does
-- not need re-asking to keep turning. The cost is that a lost "false" would leave a
-- joint driving with nothing to stop it, which is why the server throttles only the
-- "true" edge and always honours the other.
export type LimbPull = {
	limbId: LimbId,
	isPulling: boolean,
}

-- Client -> server. Which way this player wants the torso rolled: +1 left, -1 right,
-- 0 not at all. Edge-triggered like LimbPull. Left and right are the climber's own
-- sides, not the L and R in limb ids, which the model names mirrored.
--
-- Deliberately not a magnitude. A client sending 4.7 would be asking for a torque
-- nobody agreed to, so the server takes the sign and supplies the strength itself.
export type RollIntent = {
	direction: number,
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
