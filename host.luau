--!strict
-- The `issues` block: my assigned Jira issues in the active sprint(s),
-- grouped by status category, refreshed on a timer.
-- Keys: r refresh.
-- Launch args (dev only): `fixture` reads test/fixtures instead of calling
-- Jira; a second arg picks the variant: `signedout`, `empty` or `error`.

local jira = require("./jira")
local config = require("./config")
local ui = tern.ui

local TOKEN_URL = "https://id.atlassian.com/manage-profile/security/api-tokens"
local ENV_VARS = { "JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN" }
-- Fixture mode renders against a fixed clock so ages and times never drift.
local FIXTURE_NOW = jira.epoch("2026-10-07T10:00:00Z") :: number

type Category = "new" | "indeterminate" | "done"
type Signin = "missing" | "rejected"

type State = {
	cx: BlockCx,
	fixture: boolean,
	variant: string?,
	issues: { jira.Issue }?,
	sprints: { jira.Sprint },
	fetched: number?,
	loading: boolean,
	problem: string?,
	signin: Signin?,
	missing: { string },
	site: string?,
	cfg: config.Config,
	cfg_error: string?,
	timer: TimerHandle?,
}

-- A pane ID survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

local function cancel_timer(state: State)
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	cancel_timer(state)
	state.loading = false
end

-- Check this run first, not just its pane: Restart reuses the pane ID.
-- Blocks have no close hook, so callbacks also retire a disappeared pane.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function now(state: State): number
	return if state.fixture then FIXTURE_NOW else os.time()
end

local function date(state: State, fmt: string, t: number): string
	return os.date((if state.fixture then "!" else "") .. fmt, t) :: string
end

-- How long ago `t` was, compactly: `12m`, `5h`, `3d`.
local function age(state: State, t: number): string
	local s = math.max(0, now(state) - t)
	if s < 3600 then
		return math.max(1, s // 60) .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	end
	return s // 86400 .. "d"
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function button(label: string, act: string, tone: string): Node
	return with(ui.badge(label, tone), { actions = { click = act } })
end

local function open_count(issues: { jira.Issue }): number
	local n = 0
	for _, issue in issues do
		if issue.category ~= "done" then
			n += 1
		end
	end
	return n
end

local function publish(state: State, count: number)
	pcall(tern.kv.set, if state.fixture then "fixture_summary" else "summary", { at = now(state), count = count })
end

-- ---------- row actions ----------
-- Each action is a button on every row. To add one, append an entry here: the
-- row view and the click handler both read this list.
type RowAction = { id: string, label: string, tone: string, run: (cx: BlockCx, issue: jira.Issue) -> () }

local ROW_ACTIONS: { RowAction } = {
	{
		id = "open", label = "Open", tone = "accent",
		run = function(cx, issue)
			cx:open(issue.url)
		end,
	},
	{
		id = "copy", label = "Copy key", tone = "neutral",
		run = function(cx, issue)
			cx:copy(issue.key)
			cx:toast("success", "Copied " .. issue.key)
		end,
	},
}
local ACTION_PREFIX = "row:"

-- ---------- refresh ----------
local schedule: (State) -> ()

local function refresh(state: State)
	if not alive(state) or state.loading then
		return
	end
	cancel_timer(state)
	state.loading = true
	state.cfg, state.cfg_error = config.load()
	state.cx:render()

	local auth: jira.Auth? = nil
	local fixture_file: string? = nil
	if state.fixture then
		if state.variant == "signedout" then
			state.missing = { table.unpack(ENV_VARS) }
		else
			auth = { base_url = "https://example.atlassian.net", email = "demo@example.com", token = "fixture" }
			fixture_file = if state.variant == "empty" then "search_empty.json" else "search.json"
		end
	else
		local resolved = jira.resolve_auth(state.cfg.base_url, state.cfg.email)
		auth = resolved.auth
		state.missing = resolved.missing
	end

	if not auth then
		state.loading = false
		state.signin = "missing"
		state.site = nil
		state.issues = nil
		publish(state, -1)
		state.cx:render()
		schedule(state)
		return
	end
	state.site = auth.base_url
	state.signin = nil

	local function finish(result: jira.Result?, problem: jira.Problem?)
		if not alive(state) then
			return
		end
		state.loading = false
		if result then
			state.issues, state.sprints = result.issues, result.sprints
			state.fetched = now(state)
			state.problem, state.signin = nil, nil
			publish(state, open_count(result.issues))
		elseif problem and problem.kind == "auth" then
			state.signin = "rejected"
			state.issues = nil
			publish(state, -1)
		else
			state.problem = if problem then problem.message else "Unknown error."
		end
		state.cx:render()
		schedule(state)
	end

	if state.variant == "error" then
		finish(nil, { kind = "network", message = "Could not reach Jira: connection refused" })
		return
	end
	jira.load(auth, state.cfg.jql, fixture_file, finish, function() return alive(state) end)
end

schedule = function(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(state.cfg.poll_minutes * 60 * 1000, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		refresh(state)
	end)
end

-- ---------- views ----------
local CATEGORIES: { { id: Category, title: string } } = {
	{ id = "new", title = "To Do" },
	{ id = "indeterminate", title = "In Progress" },
	{ id = "done", title = "Done" },
}
local STATUS_TONE: { [string]: string } = { new = "neutral", indeterminate = "info", done = "success" }
local PRIORITY_STYLE: { [string]: string } = {
	highest = "error strong", blocker = "error strong", critical = "error strong",
	high = "warning", major = "warning",
	low = "muted", lowest = "muted", minor = "muted", trivial = "muted",
}


local function issue_row(state: State, issue: jira.Issue): Node
	local meta: { Node } = {
		ui.badge(issue.status, STATUS_TONE[issue.category]),
		ui.text({ ui.span(issue.priority, PRIORITY_STYLE[string.lower(issue.priority)]) }),
		ui.text({ ui.span(issue.issue_type, "muted") }),
	}
	if issue.points then table.insert(meta, ui.text({ ui.span(issue.points .. " pt", "num") })) end
	table.insert(meta, ui.text({ ui.span("updated " .. age(state, issue.updated) .. " ago", "muted") }))
	for _, action in ROW_ACTIONS do
		table.insert(meta, button(action.label, ACTION_PREFIX .. action.id .. "=" .. issue.key, action.tone))
	end
	return ui.node("col", { gap = "xs", key = issue.key }, {
		ui.text({ ui.link(issue.key, issue.url, "link strong"), ui.span("  "), ui.link(issue.summary, issue.url) }),
		ui.node("row", { gap = "md", wrap = true }, meta),
	})
end

local function sprint_line(state: State): { Span | string }
	local spans: { Span | string } = {}
	for i, sprint in state.sprints do
		if i > 1 then
			table.insert(spans, ui.span("  ·  ", "dim"))
		end
		table.insert(spans, ui.span(sprint.name, "strong"))
		if sprint.ends then
			table.insert(spans, ui.span("  ends " .. date(state, "%b %d", sprint.ends), "muted"))
		end
	end
	if #spans == 0 then
		table.insert(spans, ui.span("My issues", "strong"))
	end
	return spans
end

local function header(state: State): Node
	local status: { Span | string } = {}
	if state.loading then
		table.insert(status, ui.span("refreshing…", "muted"))
	elseif state.fetched then
		table.insert(status, ui.span("updated " .. date(state, "%H:%M", state.fetched), "muted"))
	end
	table.insert(status, ui.span("  ·  r to refresh", "dim"))
	return ui.node("row", { gap = "md", key = "header", wrap = true }, {
		with(ui.text(sprint_line(state)), { grow = 1 }),
		with(ui.text(status), { shrink = 0 }),
		with(button("Refresh", "refresh", "accent"), { shrink = 0 }),
	})
end

local function signin_card(state: State): Node
	local lines: { string } = {}
	if state.signin == "rejected" then
		table.insert(lines, "Jira rejected the credentials for " .. (state.site or "your site") .. ". Check the email and API token, then refresh.")
	else
		table.insert(lines, "Jira needs your site, email and an API token.")
	end
	table.insert(lines, "Set these environment variables where Tern's panes run (the session daemon), restart it, then press **r**:")
	local missing: { [string]: boolean } = {}
	for _, name in state.missing do
		missing[name] = true
	end
	local items: { { Spans } } = {}
	local notes: { [string]: string } = {
		JIRA_BASE_URL = "your site, e.g. https://acme.atlassian.net",
		JIRA_EMAIL = "the email of your Atlassian account",
		JIRA_API_TOKEN = "an API token, created on the Atlassian page below",
	}
	for _, name in ENV_VARS do
		local note = notes[name] :: string
		table.insert(items, {
			{ ui.span(name, "code") },
			{ ui.span(if missing[name] then "not set" else "set", if missing[name] then "error" else "success"), ui.span("  " .. note, "muted") },
		})
	end
	local body: { Node } = {
		ui.md(table.concat(lines, "\n\n")),
		ui.kv(items),
		ui.text({ ui.span("JIRA_BASE_URL and JIRA_EMAIL may instead be set as `base_url` and `email` in config.json. The token is read only from the environment.", "muted") }),
		ui.node("row", { gap = "sm" }, {
			button("Open API token page", "token", "accent"),
			button("Retry", "refresh", "neutral"),
		}),
	}
	return with(ui.card({ ui.span("Sign in to Jira", "strong") }, body), { tone = "warning", key = "signin" })
end

local function problem_card(state: State): Node
	local body: { Node } = {
		ui.md(state.problem or "Could not load issues."),
		ui.node("row", { gap = "sm" }, { button("Retry", "refresh", "accent") }),
	}
	return with(ui.card({ ui.span("Could not load Jira issues", "strong") }, body), { tone = "error", key = "problem" })
end

local function empty_card(): Node
	return with(
		ui.card({ ui.span("Nothing assigned in the active sprint", "strong") }, {
			ui.md("No issues match your JQL. Either nothing is assigned to you in an open sprint, or the board has no active sprint. You can change the query with `jql` in config.json."),
		}),
		{ tone = "muted", key = "empty" }
	)
end

local function sections(state: State, issues: { jira.Issue }): { Node }
	local out: { Node } = {}
	for _, category in CATEGORIES do
		local rows: { Node } = {}
		for _, issue in issues do
			if issue.category == category.id then
				table.insert(rows, issue_row(state, issue))
			end
		end
		if #rows > 0 then
			local head: { Span | string } = { ui.span(category.title, "strong"), ui.span("  " .. #rows, "muted num") }
			table.insert(out, with(ui.section(head, rows), { key = "cat-" .. category.id, collapsible = true }))
		end
	end
	return out
end

local function dock(state: State): Node?
	local lines: { Node } = {}
	if state.problem and state.issues then
		table.insert(lines, ui.text({ ui.span(state.problem, "warning"), ui.span("  showing the last list", "muted") }))
	end
	if state.cfg_error then
		table.insert(lines, ui.text({ ui.span(state.cfg_error .. "; using defaults", "warning") }))
	end
	if #lines == 0 then
		return nil
	end
	return ui.col({ ui.lines(lines) })
end

-- ---------- block ----------
local function find_issue(state: State, key: string): jira.Issue?
	local issues = state.issues
	if not issues then return nil end
	for _, issue in issues do
		if issue.key == key then
			return issue
		end
	end
	return nil
end

tern.block.define("issues", {
	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local cfg, cfg_error = config.load()
		local state: State = {
			cx = cx,
			fixture = args[1] == "fixture",
			variant = args[2],
			issues = nil,
			sprints = {},
			fetched = nil,
			loading = false,
			problem = nil,
			signin = nil,
			missing = {},
			site = nil,
			cfg = cfg,
			cfg_error = cfg_error,
			timer = nil,
		}
		running[cx.pane] = state
		refresh(state)
		return state
	end,

	title = function(state: State): string?
		if state.issues then
			return "Jira (" .. open_count(state.issues) .. ")"
		end
		return "Jira"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local children: { Node } = {}
		if state.signin then
			table.insert(children, signin_card(state))
		elseif state.issues then
			table.insert(children, header(state))
			if #state.issues == 0 then
				table.insert(children, empty_card())
			else
				for _, section in sections(state, state.issues) do
					table.insert(children, section)
				end
			end
		elseif state.problem then
			table.insert(children, problem_card(state))
		else
			table.insert(children, ui.progress(nil, "Loading issues…"))
		end
		return { main = ui.col(children), dock = dock(state) }
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		if (key.text or key.name) == "r" then
			refresh(state)
			return true
		end
		return false
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev ~= "action" or type(ev.act) ~= "string" then
			return
		end
		local act = ev.act :: string
		if act == "refresh" then
			refresh(state)
		elseif act == "token" then
			cx:open(TOKEN_URL)
		elseif string.sub(act, 1, #ACTION_PREFIX) == ACTION_PREFIX and type(ev.value) == "string" then
			local issue = find_issue(state, ev.value :: string)
			if issue then
				local id = string.sub(act, #ACTION_PREFIX + 1)
				for _, action in ROW_ACTIONS do
					if action.id == id then
						action.run(cx, issue)
					end
				end
			end
		end
	end,
})
