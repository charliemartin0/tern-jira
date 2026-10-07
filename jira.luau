--!strict
-- Jira Cloud REST API v3 client: basic auth (email + API token), the
-- `/search/jql` endpoint and `/field` lookups for the story points and sprint
-- field ids. In fixture mode, responses are read from test/fixtures instead
-- of the network. The token only ever lives in the Authorization header.

local M = {}

export type Auth = { base_url: string, email: string, token: string }
export type Problem = { kind: "auth" | "network" | "http" | "parse", message: string }
export type Issue = {
	key: string, summary: string, url: string,
	status: string, status_id: string?, category: "new" | "indeterminate" | "done",
	priority: string, issue_type: string, points: string?, updated: number,
}
export type Sprint = { id: number, name: string, ends: number?, board: number? }
-- `ranks` maps a status id to its position in the sprint boards' column order.
export type Result = { issues: { Issue }, sprints: { Sprint }, ranks: { [string]: number } }

local UA = "tern-jira/0.1.0"
local PAGE_SIZE = 100

-- Seconds since the epoch of an ISO 8601 time with optional fraction and
-- offset (`2026-10-06T14:03:11.123+0200`, `…Z`), by days-from-civil.
function M.epoch(iso: any): number?
	if type(iso) ~= "string" then return nil end
	local y, mo, d, h, mi, s, rest = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)(.*)$")
	if not (y and mo and d and h and mi and s) then return nil end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if month <= 2 then year -= 1 end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if month > 2 then month - 3 else month + 9) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local t = (era * 146097 + doe - 719468) * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
	local sign, oh, om = string.match(rest or "", "([+-])(%d%d):?(%d%d)$")
	if sign and oh and om then
		local off = (tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60
		t = if sign == "+" then t - off else t + off
	end
	return t
end

-- `acme.atlassian.net`, `https://acme.atlassian.net/` -> `https://acme.atlassian.net`.
function M.normalize_url(raw: string): string
	local url = string.gsub(raw, "^%s+", "")
	url = string.gsub(url, "%s+$", "")
	url = string.gsub(url, "/+$", "")
	local scheme = string.match(url, "^(%a[%w+.-]*)://")
	if scheme and string.lower(scheme) == "http" then
		url = "https://" .. string.sub(url, 8)
	elseif not scheme and url ~= "" then
		url = "https://" .. url
	end
	return url
end

local function trim(s: string): string
	local out = string.gsub(s, "^%s+", "")
	out = string.gsub(out, "%s+$", "")
	return out
end

-- Reads the site URL, email and token. Env vars win; config.json only fills
-- in the URL and email (the token is never read from or written to disk).
-- `missing` names the env vars that would fix whatever is absent.
function M.resolve_auth(cfg_url: string, cfg_email: string): { auth: Auth?, missing: { string } }
	local function present(v: string?): string?
		if v and string.match(v, "%S") then return trim(v) end
		return nil
	end
	local url = present(tern.getenv("JIRA_BASE_URL")) or present(cfg_url)
	local email = present(tern.getenv("JIRA_EMAIL")) or present(cfg_email)
	local token = present(tern.getenv("JIRA_API_TOKEN"))
	local missing: { string } = {}
	if not url then table.insert(missing, "JIRA_BASE_URL") end
	if not email then table.insert(missing, "JIRA_EMAIL") end
	if not token then table.insert(missing, "JIRA_API_TOKEN") end
	if url and email and token then
		return { auth = { base_url = M.normalize_url(url), email = email, token = token }, missing = missing }
	end
	return { auth = nil, missing = missing }
end

local function request(auth: Auth, method: string, path: string, body: any?, done: (any?, Problem?) -> ())
	if not string.match(auth.base_url, "^https://[^/%s@?#]+$") then
		done(nil, { kind = "network", message = "Use an HTTPS Jira site URL without a path, query or embedded credentials." })
		return
	end
	local headers: { [string]: string } = {
		Authorization = "Basic " .. tern.base64.encode(auth.email .. ":" .. auth.token),
		Accept = "application/json",
		["User-Agent"] = UA,
	}
	local payload: string? = nil
	if body ~= nil then
		headers["Content-Type"] = "application/json"
		payload = tern.json.encode(body)
	end
	local started = pcall(function()
		tern.fetch(auth.base_url .. path, { method = method, headers = headers, body = payload, timeout_ms = 30000 }, function(response: FetchResult, _)
			if response.error then
				done(nil, { kind = "network", message = if response.timed_out then "Jira did not answer within 30 seconds." else "Could not reach Jira: " .. response.error })
			elseif response.status == 401 or response.status == 403 then
				done(nil, { kind = "auth", message = "Jira rejected the email and API token." })
			elseif response.status < 200 or response.status >= 300 then
				local detail = ""
				local ok, data = pcall(tern.json.decode, response.body)
				if ok and type(data) == "table" and type(data.errorMessages) == "table" and type(data.errorMessages[1]) == "string" then
					detail = " " .. data.errorMessages[1]
				end
				done(nil, { kind = "http", message = "Jira returned HTTP " .. response.status .. " for " .. method .. " " .. path .. "." .. detail })
			else
				local ok, data = pcall(tern.json.decode, response.body)
				if not ok or type(data) ~= "table" then
					done(nil, { kind = "parse", message = "Jira returned something other than JSON." })
				else
					done(data, nil)
				end
			end
		end)
	end)
	if not started then
		done(nil, { kind = "network", message = "The Jira site URL is not valid: " .. auth.base_url })
	end
end

-- Field ids by name. Fails soft: an unreadable field list only costs the
-- optional story points and sprint info.
local function field_ids(fields: any): ({ string }, string?)
	local points: { string } = {}
	local seen_points: { [string]: boolean } = {}
	local sprint: string? = nil
	if type(fields) ~= "table" then return points, nil end
	for _, f in fields do
		if type(f) == "table" and type(f.id) == "string" then
			local name = if type(f.name) == "string" then string.lower(f.name) else ""
			local custom = if type(f.schema) == "table" then f.schema.custom else nil
			if (name == "story points" or name == "story point estimate") and not seen_points[f.id] then
				table.insert(points, f.id)
				seen_points[f.id] = true
			end
			if sprint == nil and (custom == "com.pyxis.greenhopper.jira:gh-sprint" or name == "sprint") then sprint = f.id end
		end
	end
	return points, sprint
end

local function parse(data: any, base: string, points_ids: { string }, sprint_id: string?): Result?
	if type(data.issues) ~= "table" then return nil end
	local issues: { Issue } = {}
	local sprints: { Sprint } = {}
	local seen: { [number]: boolean } = {}
	for _, raw in data.issues do
		if type(raw) ~= "table" or type(raw.fields) ~= "table" or type(raw.key) ~= "string" then continue end
		local f = raw.fields
		local status = if type(f.status) == "table" then f.status else {}
		local cat = if type(status.statusCategory) == "table" then status.statusCategory.key else nil
		local points: string? = nil
		for _, points_id in points_ids do
			if type(f[points_id]) == "number" then
				points = tostring(f[points_id])
				break
			end
		end
		table.insert(issues, {
			key = raw.key,
			summary = tostring(f.summary or ""),
			url = base .. "/browse/" .. raw.key,
			status = tostring(status.name or "Unknown"),
			status_id = if type(status.id) == "string" or type(status.id) == "number" then tostring(status.id) else nil,
			category = if cat == "done" then "done" elseif cat == "indeterminate" then "indeterminate" else "new",
			priority = if type(f.priority) == "table" then tostring(f.priority.name or "") else "",
			issue_type = if type(f.issuetype) == "table" then tostring(f.issuetype.name or "") else "",
			points = points,
			updated = M.epoch(f.updated) or os.time(),
		})
		local list = if sprint_id then f[sprint_id] else nil
		if type(list) == "table" then
			for _, sp in list do
				if type(sp) == "table" and sp.state == "active" and type(sp.id) == "number" and type(sp.name) == "string" and not seen[sp.id] then
					seen[sp.id] = true
					table.insert(sprints, { id = sp.id, name = sp.name, ends = M.epoch(sp.endDate), board = if type(sp.boardId) == "number" then sp.boardId else nil })
				end
			end
		end
	end
	table.sort(sprints, function(a, b) return a.id < b.id end)
	return { issues = issues, sprints = sprints, ranks = {} }
end

local function read_fixture(name: string): any?
	local ok, text = pcall(tern.fs.read, tern.plugin.dir .. "/test/fixtures/" .. name, 1048576)
	if not ok or not text then return nil end
	local decoded, data = pcall(tern.json.decode, text)
	return if decoded and type(data) == "table" then data else nil
end

-- Adds the status ids of a board configuration to `ranks` in board order:
-- 1 is the leftmost column; statuses sharing a column keep their listed order.
-- Statuses already ranked (by an earlier board) keep their rank.
local function add_ranks(ranks: { [string]: number }, config: any)
	local columns = if type(config) == "table" and type(config.columnConfig) == "table" then config.columnConfig.columns else nil
	if type(columns) ~= "table" then return end
	local next_rank = 1
	for _ in ranks do next_rank += 1 end
	for _, column in columns do
		local statuses = if type(column) == "table" then column.statuses else nil
		if type(statuses) ~= "table" then continue end
		for _, status in statuses do
			local id = if type(status) == "table" then status.id else nil
			if (type(id) == "string" or type(id) == "number") and ranks[tostring(id)] == nil then
				ranks[tostring(id)] = next_rank
				next_rank += 1
			end
		end
	end
end

-- Board column order for the boards of the active sprints, one configuration
-- request per board. Fails soft: with no order the view falls back to status
-- category order, so an unreadable board only costs the ordering.
local function load_ranks(auth: Auth, sprints: { Sprint }, alive: (() -> boolean)?, done: ({ [string]: number }) -> ())
	local ranks: { [string]: number } = {}
	local boards: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, sprint in sprints do
		if sprint.board and not seen[sprint.board] then
			seen[sprint.board] = true
			table.insert(boards, sprint.board)
		end
	end
	local index = 0
	local step: () -> ()
	step = function()
		if alive and not alive() then return end
		index += 1
		local board = boards[index]
		if not board then
			done(ranks)
			return
		end
		request(auth, "GET", string.format("/rest/agile/1.0/board/%d/configuration", board), nil, function(config, _)
			if alive and not alive() then return end
			add_ranks(ranks, config)
			step()
		end)
	end
	step()
end

-- Loads my issues for `jql`. `fixture` names a search response in
-- test/fixtures to read instead of calling Jira. done(result?, problem?).
function M.load(auth: Auth, jql: string, fixture: string?, done: (Result?, Problem?) -> (), alive: (() -> boolean)?)
	if fixture then
		local points_ids, sprint_id = field_ids(read_fixture("fields.json"))
		local data = read_fixture(fixture)
		local result = if data then parse(data, auth.base_url, points_ids, sprint_id) else nil
		if result then
			add_ranks(result.ranks, read_fixture("board.json"))
			done(result, nil)
		else
			done(nil, { kind = "parse", message = "fixture " .. fixture .. " missing or invalid" })
		end
		return
	end
	request(auth, "GET", "/rest/api/3/field", nil, function(fields, field_problem)
		if alive and not alive() then return end
		if field_problem and field_problem.kind == "auth" then
			done(nil, field_problem)
			return
		end
		local points_ids, sprint_id = field_ids(fields)
		local names = { "summary", "status", "priority", "issuetype", "updated" }
		for _, points_id in points_ids do table.insert(names, points_id) end
		if sprint_id then table.insert(names, sprint_id) end
		local issues: { any } = {}
		local seen_keys: { [string]: boolean } = {}
		local seen_tokens: { [string]: boolean } = {}
		local page: (string?) -> ()
		page = function(token: string?)
			if alive and not alive() then return end
			local body = { jql = jql, maxResults = PAGE_SIZE, fields = names, nextPageToken = token }
			request(auth, "POST", "/rest/api/3/search/jql", body, function(data, problem)
				if alive and not alive() then return end
				if problem or not data then done(nil, problem) return end
				if type(data.issues) ~= "table" then
					done(nil, { kind = "parse", message = "Jira's search response had no issue list." })
					return
				end
				for _, issue in data.issues do
					if type(issue) == "table" and type(issue.key) == "string" and not seen_keys[issue.key] then
						seen_keys[issue.key] = true
						table.insert(issues, issue)
					end
				end
				if data.isLast == false then
					local next_token = data.nextPageToken
					if type(next_token) ~= "string" or next_token == "" or seen_tokens[next_token] then
						done(nil, { kind = "parse", message = "Jira returned an invalid pagination token." })
						return
					end
					seen_tokens[next_token] = true
					page(next_token)
				else
					local result = parse({ issues = issues }, auth.base_url, points_ids, sprint_id)
					if not result then
						done(nil, { kind = "parse", message = "Jira's search response had no issue list." })
						return
					end
					load_ranks(auth, result.sprints, alive, function(ranks)
						result.ranks = ranks
						done(result, nil)
					end)
				end
			end)
		end
		page(nil)
	end)
end

return M
