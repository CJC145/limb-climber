--!strict

-- RemoteEvent definitions. The server creates them on first require; the client
-- waits for them to replicate.
--
-- The design doc also specifies ToolUse and AnchorSet. Those belong to phases 5
-- and 6 and are not created here until something fires them.

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

	-- Server -> client: Types.LimbState fields, passed positionally.
	LimbState = remote("LimbState"),
}

return Net
