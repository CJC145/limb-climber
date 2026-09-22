--!strict

-- RemoteEvent definitions. The server creates them on first require; the client
-- waits for them to replicate.
--
-- The design doc also specifies ToolUse and AnchorSet. Both belong to phase 6 and
-- are not created here until something fires them. AnchorSet in particular is
-- tempting to add now that AnchorService exists, but nothing places an anchor until
-- tools do -- phase 5's anchor is the start position and no client needs telling.

local RunService = game:GetService("RunService")

local function remote(name: string): RemoteEvent
	if RunService:IsServer() then
		local existing = script:FindFirstChild(name)
		if existing then
			return existing :: RemoteEvent
		end
		local created = Instance.new("RemoteEvent")
		created.Name = name
		created.Parent = script
		return created
	end
	return script:WaitForChild(name) :: RemoteEvent
end

local Net = {
	-- Client -> server: Types.LimbIntent fields, passed positionally.
	LimbIntent = remote("LimbIntent"),

	-- Client -> server: Types.LimbPull fields, passed positionally.
	--
	-- Separate from LimbIntent rather than another field on it, because the two are
	-- different shapes of traffic. An intent streams every frame and carries where the
	-- player is aiming; a pull is two events, one when the key goes down and one when
	-- it comes up, and carries nothing but which way the switch went. Folding them
	-- together would send an aim point ninety times a second for a limb that is
	-- gripped and not aiming at anything.
	LimbPull = remote("LimbPull"),

	-- Server -> client: Types.LimbState fields, passed positionally.
	LimbState = remote("LimbState"),
}

return Net
