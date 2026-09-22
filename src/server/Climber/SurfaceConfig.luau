--!strict

-- Tag -> grip-properties lookup.
--
-- The full tag table is implemented now, per docs/design.md: "Implement the full
-- tag system in phase 1 even though only Rock is needed. Adding it later means
-- revisiting every grip call site." Only Rock is reachable in phase 1 -- the tools
-- that unlock Ice and Metal arrive in phase 6.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Climber.Config)

export type SurfaceProperties = {
	Tag: string,
	BaseGrip: number,
	FailAfterSeconds: number?,
}

local SurfaceConfig = {}

-- Returns the surface properties for a part, or nil if it carries no surface tag.
-- An untagged part is not climbable: geometry has to opt in.
function SurfaceConfig.GetProperties(part: BasePart): SurfaceProperties?
	for tag, entry in Config.Surfaces do
		if CollectionService:HasTag(part, tag) then
			return {
				Tag = tag,
				BaseGrip = entry.BaseGrip,
				FailAfterSeconds = entry.FailAfterSeconds,
			}
		end
	end
	return nil
end

return SurfaceConfig
