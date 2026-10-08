# Tern Jira

[![CI](https://github.com/charliemartin0/tern-jira/actions/workflows/ci.yml/badge.svg)](https://github.com/charliemartin0/tern-jira/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Your Jira sprint, inside [Tern](https://docs.stencil.so/tern/). A block for issues assigned to you, with status groups, sprint details, quick row actions and arrows to move an issue between statuses.

Works with Jira Cloud REST API v3 using your Atlassian email and API token. No Jira CLI, project key, board ID or company-specific setup is required.

## Requirements

- Tern 0.6.0 or newer.
- A Jira Cloud site and an Atlassian API token.
- The Tern host (the session daemon, where panes run) must be able to reach your Jira site.

## Install

```sh
git clone https://github.com/charliemartin0/tern-jira.git
cd tern-jira
tern plugin link .
```

Linking loads the plugin into the daemon and existing windows; **no Tern restart is needed to install it**. Choose **Open Jira** in the command palette (`plugin.jira.open`). Without credentials, the block shows a sign-in card. After the first successful load, `jira <n>` in the status line can also open or focus the block.

Set up authentication below, then press `r` or **Refresh**. Host-side environment changes must reach the daemon, not just the shell in a tab.

## What it does

- **Jira block**: issues matching the configured JQL, grouped by their actual Jira status names with a count per group. Custom statuses such as `Review` have their own sections, even when Jira categorizes them as `To Do`. Only statuses with matching issues are shown.
- **Each row**: issue key and summary link on the first line; status, priority, issue type, story points when present, updated age and actions on a wrapping metadata line. Narrow panes keep the summary readable.
- **Row actions**: Open in Jira and Copy key. The row actions use a small action registry in `host.luau` so additional actions can be added independently.
- **Status arrows**: `←` and `→` on each row's metadata line, either side of the status badge, move the issue to the previous or next status. Clicking reads the transitions Jira offers for that issue (`GET /rest/api/3/issue/{key}/transitions`) and applies the nearest one in that direction (`POST` of the transition id). Direction follows the board column order the groups use; for statuses not on the board it falls back to category order (To Do → In Progress → Done), and a status in the same category as the current one is never guessed. The row shows `moving…` while the change is in flight, then the new status, a toast and a refresh. If there is no status in that direction, or Jira refuses (for example a transition that requires a field), a toast says so and the issue is unchanged. Only the transitions your workflow permits for you can be used; the arrows never skip to a status Jira does not offer.
- **Header**: active sprint name(s) and end date when Jira includes them in the issue's sprint field, last updated time, `r` refresh hint and a Refresh button.
- **Status line**: `jira <n>` for your non-done issues in the current result; click it to open or focus the Jira block.
- **Sign-in card**: explains missing or rejected credentials, lists the required environment variables without exposing their values, and links to Atlassian's API-token page.
- **Errors and empty results**: network/API failures show a retry card; a failed refresh preserves previously loaded issues. Empty results have a dedicated explanation.
- **Refresh**: polls every five minutes by default; press `r` or the Refresh button to refresh sooner.

The default query is:

```jql
assignee = currentUser() AND sprint in openSprints() ORDER BY status, priority DESC, updated DESC
```

The plugin uses `POST /rest/api/3/search/jql` and follows its pagination tokens, so group and status-line counts include every returned issue. It reads Jira story-point and sprint field IDs from `/rest/api/3/field`; it does not hard-code custom field IDs. Both company-managed `Story Points` and team-managed `Story point estimate` fields are supported. Story points are optional. Sprint name/end dates come from the issue's sprint field.

When active sprints include a board ID, the plugin reads `/rest/agile/1.0/board/{id}/configuration` once per board per refresh to order status sections by board columns. For multiple boards, the first board (by sprint ID) establishes the order; previously unseen statuses from later boards follow. Statuses absent from the board configuration follow the mapped statuses in category order, retaining JQL order within each category. If board IDs are missing or configurations cannot be read, all sections use that fallback order. Section names and membership always come from actual issue statuses, not categories or column names. Categories still control badge colors and the non-done status-line count.

## Sign in

Create an API token at [Atlassian API tokens](https://id.atlassian.com/manage-profile/security/api-tokens). Set these variables in the environment of the machine running Tern's session daemon:

```sh
export JIRA_BASE_URL="https://your-site.atlassian.net"
export JIRA_EMAIL="you@example.com"
export JIRA_API_TOKEN="your-api-token"
```

The host-side plugin reads the daemon's environment, not the environment of a shell inside a tab. If the daemon was already running when you set these variables, restart it only when safe for your live panes so it receives the new environment. This is separate from installing the plugin, which does not need a restart.

The token is only read from `JIRA_API_TOKEN`; it is never saved in `config.json`, logged, or included in a toast. Environment variables override the URL and email from config.

Requests require HTTPS. A bare hostname or an explicit `http://` site URL is
normalized to HTTPS before authentication is sent. URLs with embedded
credentials, a path or a query are rejected.

## Config

On first open, the plugin creates `config.json` in Tern's Jira plugin data directory (Linux: `~/.local/state/tern/plugin-data/jira/config.json`). It reads the file on each refresh. Missing or wrongly typed values use defaults; malformed JSON uses defaults and displays a warning in the block.

| Key | Default | Notes |
|---|---|---|
| `base_url` | `""` | Jira Cloud site URL; overridden by `JIRA_BASE_URL`. A bare hostname is accepted. |
| `email` | `""` | Atlassian account email; overridden by `JIRA_EMAIL`. |
| `jql` | `"assignee = currentUser() AND sprint in openSprints() ORDER BY status, priority DESC, updated DESC"` | Search query sent to Jira. |
| `hidden_statuses` | `[]` | Status names to leave out, matched case-insensitively against the issue's status name. Hidden issues have no section and are excluded from the block title and status-line counts. Non-string entries are ignored. Use `jql` instead to exclude them server-side. |
| `poll_minutes` | `5` | Automatic refresh interval, clamped to 1–60 minutes. |

Example (do not put an API token in this file):

```json
{
  "base_url": "https://your-site.atlassian.net",
  "email": "you@example.com",
  "jql": "assignee = currentUser() AND sprint in openSprints() ORDER BY status, priority DESC, updated DESC",
  "hidden_statuses": ["Rejected"],
  "poll_minutes": 5
}
```

## Limits

- Jira Cloud only. Use a site-scoped API token without scopes for Basic auth against your site URL; tokens requiring the `api.atlassian.com/ex/jira/...` gateway are not supported.
- Only active sprint names/end dates returned on matching issues are shown. Jira may omit sprint metadata from an issue response; in that case issue data still renders without sprint details.
- Story points are omitted when the site has no supported story-point field or the field is not populated.
- Status changes are one step at a time through Jira's transition list. Transitions that need input (a resolution or other screen fields) are refused by Jira and reported in a toast; open the issue in Jira for those. Comments, branch creation and sending issues to an agent are not implemented.

## Privacy

- Credentials belong in your local daemon environment; the API token has no config-file fallback.
- Site URL and email can be stored in your local plugin config, never in the checkout.
- Fixtures, example addresses and issue keys are synthetic. Screenshot data comes from those fixtures, not a live Jira account.
- Custom field IDs in fixtures are examples only. Live requests discover your site's field IDs instead of assuming a particular Jira project.


## Testing

Synthetic fixtures in `test/fixtures` keep the block deterministic and make no network requests:

```sh
# Open a fixture block in a fresh Tern window
JIRA_AUTOOPEN=fixture tern --control /tmp/jira.sock .

# Variants for sign-in and empty-result UI
JIRA_AUTOOPEN=fixture-signedout tern --control /tmp/jira.sock .
JIRA_AUTOOPEN=fixture-empty tern --control /tmp/jira.sock .
JIRA_AUTOOPEN=fixture-error tern --control /tmp/jira.sock .

# Live Jira data (requires host-side environment variables or config)
JIRA_AUTOOPEN=live tern --control /tmp/jira.sock .
```

Capture the block with the Tern control endpoint (not `grim`):

```sh
tern ctl --control /tmp/jira.sock shot issues
```

Float the test window and size its content to 1920×1080 physical pixels
(1536×864 logical pixels at display scale 1.25). Check the saved PNG with
`identify`. Keep QA captures outside the repository.
Use a fresh window and a unique control socket for each variant.

API and refresh-state regressions (requires Python 3 and the
[Luau CLI](https://github.com/luau-lang/luau/releases)):

```sh
python3 test/smoke.py --luau luau
```

This executes the actual Luau modules with deterministic HTTP/UI boundaries:
mixed story-point fields, multi-page/deduplicated results, optional fields,
auth failures, invalid cursors, closed panes, HTTPS, timezone offsets,
sign-in/refresh recovery, custom-status grouping (including `Review` in Jira's
`To Do` category), board ordering/deduplication/fallback, and status arrows
(board/category direction, transition POST, refresh, Jira refusals, no-op edges,
fixture mode). It does not authenticate to a live Jira site.

The **Plugin checks** GitHub Actions job compiles the four Luau modules and runs this regression harness on pushes and pull requests. It needs no Jira credentials or running Tern daemon; it is not a live Jira API or GUI test.

Before contributing, run the regression harness and compile the modules:

```sh
luau-compile --null config.luau jira.luau host.luau window.luau
python3 test/smoke.py --luau luau
```

Run `tern plugin types .` to regenerate the checked-in SDK declarations.

## License

[MIT](LICENSE).
