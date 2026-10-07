--!strict
-- The window half: an "Open Jira" palette command and a status line segment
-- with the number of my open issues in the sprint. The segment reads only the
-- summary the host half saved in tern.kv; this half makes no network calls.

local KIND = "jira.issues"
local ACTION = "plugin.jira.open"
local WATCH_MS = 30 * 1000

local function open_block(cx: WindowCx, args: { string }?)
	for _, pane in cx.session:panes() do
		if pane.block == KIND then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, args, "beside") == nil then
		cx:toast("error", "Jira is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open Jira",
	icon = "ticket",
	run = function(cx: WindowCx)
		open_block(cx, nil)
	end,
})

-- Dev: JIRA_AUTOOPEN=fixture[-signedout|-empty|-error] opens the block against
-- test/fixtures (no network, fixed clock); JIRA_AUTOOPEN=live opens it live.
-- No effect when unset. A fixture run keeps its summary under its own kv key
-- so it never changes a real status segment.
local AUTO = tern.getenv("JIRA_AUTOOPEN") or ""
local SUMMARY_KEY = if string.sub(AUTO, 1, 7) == "fixture" then "fixture_summary" else "summary"

local function summary(): { [string]: any }?
	local ok, s = pcall(tern.kv.get, SUMMARY_KEY)
	if ok and type(s) == "table" and type(s.at) == "number" and type(s.count) == "number" then
		return s
	end
	return nil
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local s = summary()
	if not s or (s.count :: number) < 0 then
		return nil
	end
	local n = s.count :: number
	return { { text = "jira " .. n, icon = "ticket", tone = if n > 0 then "accent" else "muted", command = ACTION } }
end)

local watch: TimerHandle? = nil
local seen = ""

local function stamp(): string
	local s = summary()
	return if s then tostring(s.at) .. ":" .. tostring(s.count) else "none"
end

local function arm()
	if watch ~= nil then
		return
	end
	watch = tern.timer(WATCH_MS, function(_cx)
		watch = nil
		local now = stamp()
		if now ~= seen then
			seen = now
			tern.chrome.refresh()
		end
		arm()
	end)
end

tern.on("window_start", function(cx: WindowCx)
	seen = stamp()
	arm()
	local variant = string.match(AUTO, "^fixture%-(%a+)$")
	local args: { string }? = nil
	if AUTO == "fixture" then
		args = { "fixture" }
	elseif variant then
		args = { "fixture", variant }
	elseif AUTO ~= "live" then
		return
	end
	if cx:new_block(KIND, args, "beside") == nil then
		tern.log.warn("jira: new_block returned nil (the block is not available on this window's host)")
	end
end)

arm()
