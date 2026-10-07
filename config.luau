--!strict
local M = {}

export type Config = { base_url: string, email: string, jql: string, hidden_statuses: { string }, poll_minutes: number }

local DEFAULTS: Config = {
	base_url = "",
	email = "",
	jql = "assignee = currentUser() AND sprint in openSprints() ORDER BY status, priority DESC, updated DESC",
	hidden_statuses = {},
	poll_minutes = 5,
}

local function str(data: any, key: string, fallback: string): string
	return if type(data[key]) == "string" then data[key] else fallback
end

-- A list of non-empty strings; anything else in the list is ignored.
local function names(data: any, key: string): { string }
	local out: { string } = {}
	if type(data[key]) == "table" then
		for _, v in data[key] do
			if type(v) == "string" and string.match(v, "%S") then
				table.insert(out, v)
			end
		end
	end
	return out
end

function M.load(): (Config, string?)
	local path = tern.plugin.data .. "/config.json"
	if not tern.fs.exists(path) then
		pcall(tern.fs.write, path, tern.json.encode(DEFAULTS, true))
		return table.clone(DEFAULTS), nil
	end
	local ok, text = pcall(tern.fs.read, path, 65536)
	if not ok or not text then return table.clone(DEFAULTS), "Could not read config.json" end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded or type(data) ~= "table" then return table.clone(DEFAULTS), "Invalid config.json" end
	local minutes = data.poll_minutes
	if type(minutes) ~= "number" or minutes ~= minutes then minutes = DEFAULTS.poll_minutes end
	return {
		base_url = str(data, "base_url", DEFAULTS.base_url),
		email = str(data, "email", DEFAULTS.email),
		jql = str(data, "jql", DEFAULTS.jql),
		hidden_statuses = names(data, "hidden_statuses"),
		poll_minutes = math.clamp(math.floor(minutes), 1, 60),
	}, nil
end

return M
