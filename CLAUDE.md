# Co-op Limb Climber

A 1–4 player Roblox climbing game. Players share one ragdoll body and each control
individual limbs. Physics-driven, server-authoritative, first person.

## Read this first

The technical design document is authoritative. It is at:

    docs/design.md

Read it in full at the start of every session before writing any code.
If anything below contradicts it, the design document wins.

## Current phase

    PHASE: 1
    STATUS: not started

Update this block when a phase is accepted. Build only the current phase.

## Phase discipline

This is the most important rule in this file.

- Build **only** the phase named above. Do not implement anything from a later phase,
  even if it seems trivial, related, or "while we're here".
- Do not add features, helpers, abstractions or polish that the current phase does not
  require. Speculative structure is the main way this codebase would rot.
- If finishing the current phase appears to require something from a later phase, stop
  and say so. Do not resolve it yourself.

## When the design seems wrong

The design document was written before the code existed, so parts of it will turn out to
be wrong. That is expected and fine.

When that happens: **stop and explain the problem.** Do not silently pick a different
approach. State what the doc says, what goes wrong, and what you would do instead. The
human decides, and the doc gets updated before work continues.

A session that quietly deviates from the spec is worse than a session that stops.

## Locked decisions

These are settled. Do not re-open, re-litigate, or "improve" them.

1. No mid-run joining. Limbs assigned at run start; session locked.
2. Tools are consumable.
3. No global fall reset. Player-placed anchors are the checkpoint system.
4. Limbs collide with the torso. Segments within one limb do not collide with each other.
5. The HUD communicates limb intent visually. Never assume voice chat.
6. Physics-driven, not snap-to-hold. Limbs are never teleported to valid positions.
7. The server owns the physics body. Always `SetNetworkOwner(nil)` on rig parts.

## Architecture invariants

Violating any of these means the work is wrong regardless of whether it runs.

- **No Humanoid instance anywhere.** Not on the climber, not on players.
  `Players.CharacterAutoLoads = false`.
- **No Motor6D.** Joints are constraints only. Never mix the two systems on one joint.
- **All grip decisions flow through `CanGrip(limb, surfacePart, equippedTools)`.**
  Never special-case a surface or tool anywhere else.
- **All tunable values live in `ReplicatedStorage/Climber/Config`.** No magic numbers
  in system modules. If a value might need tuning, it belongs in Config.
- **`LimbAssignment` is the only source of truth** for which player owns which limb.
  No other module stores that mapping.
- **Server-authoritative.** Clients send intent, never state. Rate-limit `LimbIntent`.

## Module layout

Do not invent a different structure.

    ServerScriptService/Climber/
        ClimberRig        rig construction, network ownership
        GripService       grip/release, constraints, stamina
        LimbAssignment    player -> limb mapping
        ToolService       pickups, shared inventory, anchor placement
        AnchorService     checkpoints, fall detection, respawn
        SurfaceConfig     tag -> grip properties

    StarterPlayerScripts/Climber/
        InputRouter       keys -> limb intents, own limbs only
        TargetReticle     local, instant, predicted aim point
        CameraController  head-cam, focus-cam, third-person toggle
        HUD               stamina, inventory, limb ownership

    ReplicatedStorage/Climber/
        Config            every tunable value
        Net               RemoteEvent definitions
        Types             shared Luau types

## Working agreements

- **Ask before creating new modules.** The layout above is deliberate.
- **Luau strict mode** (`--!strict`) on all new files.
- **Commit per working increment**, not per phase. Small commits make physics
  regressions findable.
- **Never edit the .rbxl directly.** All scripts are files on disk, synced via Rojo.
- **Report uncertainty.** If something is tuned by guess rather than reason, say which
  values are guesses so they get tested rather than trusted.

## Things that will waste a day if forgotten

- `CustomPhysicalProperties` must be set explicitly on all 11 rig parts.
- Every constraint needs an `Attachment` on **both** connected parts.
- `SetNetworkOwner(nil)` must be re-applied after any rig respawn.
- `AlignPosition.MaxForce` is the primary feel dial. Expect to tune it, keep it in Config.
- Elbows and knees are `HingeConstraint`, not ball sockets.
- Test with simulated latency from phase 3 onward, not at the end.

## Human handoff points

Modelling and spatial work is done by the human in Studio, not by script generation:

- **Phase 2** — the 11-part climber rig, proportions and attachment placement
- **Phase 6** — tool models (piton, rope, ice screw, gloves, hook)
- **Phase 7** — all level geometry, surface tagging, tool placement

When a phase reaches one of these, stop and ask for the asset rather than generating
a placeholder and building on top of it.
