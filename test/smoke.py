#!/usr/bin/env python3
"""Exercise the actual Luau modules with a deterministic transport/UI boundary.

Requires Python 3 and the upstream Luau CLI. No Jira credentials or network.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, list):
        return "{" + ",".join(lua(v) for v in value) + "}"
    return "{" + ",".join(f"[{lua(k)}]={lua(v)}" for k, v in value.items()) + "}"


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--luau", default="luau", help="Path to the Luau CLI")
    opts = args.parse_args()
    root = Path(__file__).resolve().parent.parent
    fixtures = {p.name: json.loads(p.read_text()) for p in (root / "test/fixtures").glob("*.json")}
    script = "local fixtures = " + lua(fixtures) + "\n"
    script += r'''
local env = {}
local encoded = {}
local serial = 0
local files = {}
local responses = {}
local calls = {}
local pane_live = true
local summaries = {}
local block = nil
local timers = {}
local tern = {
    plugin = { dir = "/plugin", data = "/data" },
    getenv = function(name) return env[name] end,
    base64 = { encode = function(bytes) return "encoded-auth" end },
    json = {
        encode = function(data)
            serial += 1
            local key = "json-" .. serial
            encoded[key] = data
            return key
        end,
        decode = function(text)
            if encoded[text] then return encoded[text] end
            if fixtures[text] then return fixtures[text] end
            error("bad JSON")
        end,
    },
    fs = {
        exists = function(path) return files[path] ~= nil end,
        read = function(path)
            if files[path] then return files[path] end
            local name = string.match(path, "/test/fixtures/(.+)$")
            if name and fixtures[name] then return name end
            error("missing file")
        end,
        write = function(path, text) files[path] = text end,
    },
    fetch = function(url, opts, cb)
        table.insert(calls, { url = url, opts = opts, body = opts.body and encoded[opts.body] })
        local response = table.remove(responses, 1)
        assert(response, "unexpected HTTP request")
        cb(response)
    end,
    pane = { list = function() return if pane_live then { { pane = 1 } } else {} end },
    kv = { set = function(key, value) summaries[key] = value end },
    timer = function(ms, cb)
        local timer = { ms = ms, callback = cb, canceled = false }
        function timer:cancel() self.canceled = true end
        table.insert(timers, timer)
        return timer
    end,
    block = { define = function(id, def) block = def end },
    ui = {},
}
local ui = tern.ui
ui.span = function(t, s) return { t = t, s = s } end
ui.link = function(t, href, s) return { t = t, href = href, s = s } end
ui.node = function(k, p, c) return { k = k, p = p or {}, c = c } end
ui.col = function(c) return ui.node("col", {}, c) end
ui.lines = ui.col
ui.text = function(spans) return ui.node("text", { spans = spans }) end
ui.badge = function(text, tone) return ui.node("badge", { text = text, tone = tone }) end
ui.card = function(head, children) return ui.node("card", { head = head }, children) end
ui.section = function(head, children) return ui.node("section", { head = head }, children) end
ui.row = function(children) return ui.node("row", {}, children) end
ui.kv = function(items) return ui.node("kv", { items = items }) end
ui.md = function(text) return ui.node("md", { text = text }) end
ui.progress = function(value, label) return ui.node("progress", { value = value, label = label }) end
local toasts = {}
local cx = { pane = 1 }
function cx:render() end
function cx:toast(level, text) table.insert(toasts, { level = level, text = text }) end
local function response(data, status)
    return { status = status or 200, body = tern.json.encode(data), headers = {} }
end
'''
    for module in ("jira", "config"):
        script += f"local {module} = (function()\n{(root / (module + '.luau')).read_text()}\nend)()\n"
    script += "local function require(name)\nif name == './jira' then return jira elseif name == './config' then return config else error(name) end\nend\n"
    script += "do\n" + (root / "host.luau").read_text() + "\nend\n"
    script += r'''
local auth = { base_url = "https://example.atlassian.net", email = "demo@example.com", token = "synthetic" }
local query = "assignee = currentUser() AND sprint in openSprints()"
local loaded, problem = nil, nil
local function done(result, err) loaded, problem = result, err end
local function reset()
    calls, responses, loaded, problem = {}, {}, nil, nil
end

-- Mixed company/team-managed story-point fields: each issue must retain its estimate.
-- Page boundaries may repeat an issue; count and ordering must remain correct.
reset()
responses = {
    response(fixtures["fields.json"]),
    response({ issues = { fixtures["search.json"].issues[1] }, isLast = false, nextPageToken = "page-2" }),
    response({ issues = { fixtures["search.json"].issues[1], fixtures["search.json"].issues[2] }, isLast = true }),
}
jira.load(auth, query, nil, done)
assert(not problem and loaded and #loaded.issues == 2)
assert(loaded.issues[1].key == "DEMO-142" and loaded.issues[1].points == "5")
assert(loaded.issues[2].key == "DEMO-151" and loaded.issues[2].points == "3")
assert(#loaded.sprints == 1 and loaded.sprints[1].name == "Sprint 24")
assert(loaded.sprints[1].ends == jira.epoch("2026-10-14T16:00:00Z"))
assert(calls[2].body.nextPageToken == nil and calls[3].body.nextPageToken == "page-2")
assert(calls[2].url == "https://example.atlassian.net/rest/api/3/search/jql")

-- Optional field lookup failures must not prevent basic issue data from loading.
reset()
responses = { response({}, 500), response(fixtures["search.json"]) }
jira.load(auth, query, nil, done)
assert(not problem and loaded.issues[1].points == nil and #loaded.sprints == 0)
assert(loaded.issues[1].summary == fixtures["search.json"].issues[1].fields.summary)

-- Auth rejection stops before search. Never forward server text containing secrets.
reset()
responses = { response({ errorMessages = { "synthetic" } }, 401) }
jira.load(auth, query, nil, done)
assert(not loaded and problem.kind == "auth" and #calls == 1)
assert(not string.find(problem.message, auth.token, 1, true))

-- A broken/repeating cursor must surface an error, not publish a partial count.
reset()
responses = {
    response(fixtures["fields.json"]),
    response({ issues = {}, isLast = false, nextPageToken = "repeat" }),
    response({ issues = {}, isLast = false, nextPageToken = "repeat" }),
}
jira.load(auth, query, nil, done)
assert(not loaded and problem.kind == "parse" and #calls == 3)

-- Callback liveness stops additional page requests when the block closes.
reset()
local alive = true
local original_fetch = tern.fetch
tern.fetch = function(url, opts, cb)
    original_fetch(url, opts, function(r)
        if string.find(url, "search/jql", 1, true) then alive = false end
        cb(r)
    end)
end
responses = { response(fixtures["fields.json"]), response({ issues = {}, isLast = false, nextPageToken = "unused" }) }
jira.load(auth, query, nil, done, function() return alive end)
assert(not loaded and not problem and #calls == 2)
tern.fetch = original_fetch

-- URL and email config fallback, env precedence, and HTTPS before Basic auth.
env = { JIRA_API_TOKEN = "synthetic" }
local resolved = jira.resolve_auth("http://example.atlassian.net/", "demo@example.com")
assert(resolved.auth.base_url == "https://example.atlassian.net")
env.JIRA_BASE_URL, env.JIRA_EMAIL = "other.atlassian.net", "env@example.com"
resolved = jira.resolve_auth("example.atlassian.net", "demo@example.com")
assert(resolved.auth.base_url == "https://other.atlassian.net" and resolved.auth.email == "env@example.com")
reset()
jira.load({ base_url = "ftp://example.atlassian.net", email = auth.email, token = auth.token }, query, nil, done)
assert(not loaded and problem.kind == "network" and #calls == 0)
assert(jira.epoch("2026-10-07T12:00:00.000+0200") == jira.epoch("2026-10-07T10:00:00Z"))
assert(jira.epoch("2026-10-07T05:00:00-05:00") == jira.epoch("2026-10-07T10:00:00Z"))

-- Missing -> supplied credentials -> HTTP failure must show the real problem,
-- not keep the old sign-in card. Refresh errors preserve the last successful list.
env = {}
local state = block.init(cx, {}, nil)
assert(state.signin == "missing")
env = { JIRA_BASE_URL = auth.base_url, JIRA_EMAIL = auth.email, JIRA_API_TOKEN = auth.token }
responses = { response(fixtures["fields.json"]), response({}, 400) }
block.key(state, { name = "r" }, cx)
assert(state.signin == nil and state.problem and not state.issues)
assert(block.view(state, cx).main.c[1].p.key == "problem")
responses = { response(fixtures["fields.json"]), response(fixtures["search.json"]) }
block.key(state, { name = "r" }, cx)
assert(not state.problem and #state.issues == 7 and summaries.summary.count == 5)
responses = { response(fixtures["fields.json"]), { status = 0, body = "", error = "offline", headers = {} } }
block.key(state, { name = "r" }, cx)
assert(state.problem and #state.issues == 7 and state.signin == nil)

-- Fixtures have a separate summary and signed-out cannot keep an old count.
state = block.init(cx, { "fixture" }, nil)
assert(summaries.fixture_summary.count == 5 and state.issues[1].points == "5")

-- Review has category "new", but must never share the To Do section.
local function expect_sections(state, expected)
    local sections = block.view(state, cx).main.c
    assert(#sections == #expected + 1, "wrong number of status sections")
    for i, group in expected do
        local section = sections[i + 1]
        assert(section.p.head[1].t == group.name, "wrong status heading")
        assert(#section.c == #group.keys, "wrong issue count for " .. group.name)
        for j, key in group.keys do
            assert(section.c[j].p.key == key, key .. " in wrong status group or JQL order")
        end
    end
end
local board_order = {
    { name = "To Do", keys = { "DEMO-160", "DEMO-163" } },
    { name = "In Progress", keys = { "DEMO-142", "DEMO-138" } },
    { name = "Review", keys = { "DEMO-151" } },
    { name = "Done", keys = { "DEMO-119", "DEMO-125" } },
}
expect_sections(state, board_order)

-- A real load discovers the board through the sprint field. Several sprints
-- on the same board must use one configuration and retain its column order.
local board_search = table.clone(fixtures["search.json"])
board_search.issues = {}
for i, raw in fixtures["search.json"].issues do
    local issue = table.clone(raw)
    issue.fields = table.clone(raw.fields)
    issue.fields.customfield_10020 = {
        { id = if i % 2 == 0 then 78 else 77, name = "Sprint", state = "active", boardId = 17 },
    }
    table.insert(board_search.issues, issue)
end
reset()
responses = { response(fixtures["fields.json"]), response(board_search), response(fixtures["board.json"]) }
state = block.init(cx, {}, nil)
assert(not state.problem and not state.signin and summaries.summary.count == 5)
expect_sections(state, board_order)
assert(#calls == 3, "duplicate board configuration request")

-- Missing/inaccessible board metadata changes only order, not grouping.
local fallback_order = {
    { name = "Review", keys = { "DEMO-151" } },
    { name = "To Do", keys = { "DEMO-160", "DEMO-163" } },
    { name = "In Progress", keys = { "DEMO-142", "DEMO-138" } },
    { name = "Done", keys = { "DEMO-119", "DEMO-125" } },
}
responses = { response(fixtures["fields.json"]), response(board_search), response({}, 403) }
block.key(state, { name = "r" }, cx)
assert(not state.problem and not state.signin and summaries.summary.count == 5)
expect_sections(state, fallback_order)
responses = { response(fixtures["fields.json"]), response(fixtures["search.json"]) }
block.key(state, { name = "r" }, cx)
expect_sections(state, fallback_order)

-- A newly added workflow status is represented without changing plugin code.
local extra = table.clone(board_search.issues[1])
extra.key = "DEMO-200"
extra.fields = table.clone(extra.fields)
extra.fields.status = { id = "20000", name = "Ready for QA", statusCategory = { key = "indeterminate" } }
table.insert(board_search.issues, extra)
responses = { response(fixtures["fields.json"]), response(board_search), response(fixtures["board.json"]) }
block.key(state, { name = "r" }, cx)
local with_unmapped = table.clone(board_order)
table.insert(with_unmapped, { name = "Ready for QA", keys = { "DEMO-200" } })
expect_sections(state, with_unmapped)

-- `hidden_statuses` drops issues by status name (case-insensitive) before they
-- are grouped or counted; non-string entries are ignored; emptying it restores them.
files["/data/config.json"] = tern.json.encode({ hidden_statuses = { "REVIEW", " ", 7, "done" } })
responses = { response(fixtures["fields.json"]), response(fixtures["search.json"]) }
block.key(state, { name = "r" }, cx)
expect_sections(state, {
    { name = "To Do", keys = { "DEMO-160", "DEMO-163" } },
    { name = "In Progress", keys = { "DEMO-142", "DEMO-138" } },
})
assert(#state.issues == 4 and summaries.summary.count == 4 and block.title(state) == "Jira (4)")
files["/data/config.json"] = tern.json.encode({ hidden_statuses = {} })
responses = { response(fixtures["fields.json"]), response(fixtures["search.json"]) }
block.key(state, { name = "r" }, cx)
assert(#state.issues == 7 and summaries.summary.count == 5)

-- Status arrows: the nearest transition in board order, or in category order
-- when the board is unknown; same-category statuses are never guessed.
local offered
jira.transitions(auth, "DEMO-1", true, function(list) offered = list end)
assert(#offered == 4 and offered[3].status == "Review" and offered[3].category == "new" and offered[3].id == "31")
local function pick(status_id, status, category, ranks, dir)
    local t = jira.pick_transition(offered, { status_id = status_id, status = status, category = category }, ranks, dir)
    return t and t.status
end
local board = { ["10002"] = 1, ["10000"] = 2, ["10001"] = 3, ["10003"] = 4 }
assert(pick("10000", "In Progress", "indeterminate", board, 1) == "Review")
assert(pick("10000", "In Progress", "indeterminate", board, -1) == "To Do")
assert(pick("10003", "Done", "done", board, 1) == nil and pick("10002", "To Do", "new", board, -1) == nil)
assert(pick("10001", "Review", "new", board, -1) == "In Progress")
assert(pick("10000", "In Progress", "indeterminate", {}, 1) == "Done")
assert(pick("10000", "In Progress", "indeterminate", {}, -1) == "To Do")
assert(pick("10001", "Review", "new", {}, -1) == nil and pick("10001", "Review", "new", {}, 1) == "In Progress")

local function status_of(state, key)
    for _, issue in state.issues do if issue.key == key then return issue.status end end
end
local function click(state, act, key) block.event(state, { ev = "action", act = act, value = key }, cx) end
reset()
responses = { response(fixtures["fields.json"]), response(board_search), response(fixtures["board.json"]) }
state = block.init(cx, {}, nil)
local row_meta = block.view(state, cx).main.c[3].c[1].c[2].c
assert(row_meta[1].p.actions.click == "move:prev=DEMO-142" and row_meta[2].p.text == "In Progress")
assert(row_meta[3].p.actions.click == "move:next=DEMO-142")

-- A successful move posts the transition, shows the new status at once and refreshes.
local moved = table.clone(board_search)
moved.issues = table.clone(board_search.issues)
moved.issues[1] = table.clone(moved.issues[1])
moved.issues[1].fields = table.clone(moved.issues[1].fields)
moved.issues[1].fields.status = { id = "10001", name = "Review", statusCategory = { key = "new" } }
reset()
toasts = {}
responses = {
    response(fixtures["transitions.json"]), { status = 204, body = "", headers = {} },
    response(fixtures["fields.json"]), response(moved), response(fixtures["board.json"]),
}
click(state, "move:next", "DEMO-142")
assert(calls[1].url == "https://example.atlassian.net/rest/api/3/issue/DEMO-142/transitions" and calls[1].opts.method == "GET")
assert(calls[2].opts.method == "POST" and calls[2].url == calls[1].url and calls[2].body.transition.id == "31")
assert(#calls == 5 and status_of(state, "DEMO-142") == "Review" and not state.moving["DEMO-142"])
assert(#toasts == 1 and toasts[1].level == "success" and toasts[1].text == "DEMO-142 → Review")

-- Jira refusing the transition (e.g. a required field) leaves the issue alone and says why.
reset()
toasts = {}
responses = { response(fixtures["transitions.json"]), response({ errors = { resolution = "Field 'resolution' is required" } }, 400) }
click(state, "move:next", "DEMO-142")
assert(#calls == 2 and status_of(state, "DEMO-142") == "Review" and not state.moving["DEMO-142"])
assert(#toasts == 1 and toasts[1].level == "error" and string.find(toasts[1].text, "resolution", 1, true))

-- Nothing after the last status, an unreadable transition list, and a click already in flight.
reset()
toasts = {}
responses = { response(fixtures["transitions.json"]) }
click(state, "move:next", "DEMO-119")
assert(#calls == 1 and #toasts == 1 and toasts[1].text == "DEMO-119 has no status after Done" and not state.moving["DEMO-119"])
responses = { response({}, 500) }
click(state, "move:prev", "DEMO-119")
assert(#toasts == 2 and string.find(toasts[2].text, "Could not read transitions for DEMO-119", 1, true))
reset()
state.moving["DEMO-138"] = true
click(state, "move:prev", "DEMO-138")
assert(#calls == 0)
state.moving["DEMO-138"] = nil

-- A 403 on transitions is a permission problem, not a sign-out; a bad key never reaches a URL;
-- a key not in the list is ignored.
reset()
toasts = {}
responses = { response({}, 403) }
click(state, "move:next", "DEMO-119")
assert(#calls == 1 and state.signin == nil and #toasts == 1 and string.find(toasts[1].text, "does not let this account", 1, true))
reset()
local bad
jira.transition(auth, "../x", "1", false, function(p) bad = p end)
assert(#calls == 0 and bad.kind == "parse")
click(state, "move:next", "NOPE-1")
assert(#calls == 0)

-- A change made while a refresh is in flight triggers one more refresh once it finishes.
reset()
state.loading = true
responses = { response(fixtures["transitions.json"]), { status = 204, body = "", headers = {} } }
click(state, "move:prev", "DEMO-138")
assert(#calls == 2 and state.stale)
state.loading = false
responses = { response(fixtures["fields.json"]), response(fixtures["search.json"]), response(fixtures["fields.json"]), response(fixtures["search.json"]) }
block.key(state, { name = "r" }, cx)
assert(#calls == 6 and not state.stale)

-- Fixture mode moves locally without any request and keeps the status-line count in step.
reset()
state = block.init(cx, { "fixture" }, nil)
click(state, "move:next", "DEMO-138")
assert(status_of(state, "DEMO-138") == "Review" and summaries.fixture_summary.count == 5 and #calls == 0)
click(state, "move:next", "DEMO-138")
assert(status_of(state, "DEMO-138") == "Done" and summaries.fixture_summary.count == 4)

state = block.init(cx, { "fixture", "signedout" }, nil)
assert(state.signin == "missing" and summaries.fixture_summary.count == -1)
state = block.init(cx, { "fixture", "empty" }, nil)
assert(#state.issues == 0 and summaries.fixture_summary.count == 0)
assert(block.view(state, cx).main.c[2].p.key == "empty")
print("PASS: mixed estimates, pagination/dedup, optional fields, auth, cursor errors, liveness, HTTPS, offsets, refresh recovery, fixture states, dynamic statuses, board ordering/dedup/fallback, hidden statuses, status arrows")
'''
    with tempfile.TemporaryDirectory(prefix="jira-smoke-") as tmp:
        path = Path(tmp) / "smoke.luau"
        path.write_text(script)
        subprocess.run([opts.luau, str(path)], check=True, cwd=root)


if __name__ == "__main__":
    main()
