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
local cx = { pane = 1 }
function cx:render() end
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
state = block.init(cx, { "fixture", "signedout" }, nil)
assert(state.signin == "missing" and summaries.fixture_summary.count == -1)
state = block.init(cx, { "fixture", "empty" }, nil)
assert(#state.issues == 0 and summaries.fixture_summary.count == 0)
assert(block.view(state, cx).main.c[2].p.key == "empty")
print("PASS: mixed estimates, pagination/dedup, optional fields, auth, cursor errors, liveness, HTTPS, offsets, refresh recovery, fixture states")
'''
    with tempfile.TemporaryDirectory(prefix="jira-smoke-") as tmp:
        path = Path(tmp) / "smoke.luau"
        path.write_text(script)
        subprocess.run([opts.luau, str(path)], check=True, cwd=root)


if __name__ == "__main__":
    main()
