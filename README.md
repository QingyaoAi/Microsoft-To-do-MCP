# mstodo-mcp

MCP server for reading and editing Microsoft To Do through Microsoft Graph, plus a
Claude Code skill that teaches Claude how to use it.

Requirements: [uv](https://docs.astral.sh/uv/) and a Microsoft account with To Do. The server
itself runs anywhere Python does; the sign-in keep-alive, dialogs and notifications are
macOS-only.

## Setup

```bash
git clone https://github.com/QingyaoAi/Microsoft-To-do-MCP.git
cd Microsoft-To-do-MCP
uv sync                       # install into .venv (Python 3.12, pinned by uv)
.venv/bin/mstodo-mcp login    # one-time device-code sign-in in the browser
.venv/bin/mstodo-mcp status   # check sign-in
claude mcp add --scope user mstodo -- "$PWD/.venv/bin/mstodo-mcp"
```

Optional: install the skill so every Claude Code session knows how to use the tools well
(find tasks before editing, ask when a name is ambiguous, date handling, limits):

```bash
mkdir -p ~/.claude/skills && cp -r skills/ms-todo ~/.claude/skills/
```

Sign-in uses Microsoft's public "Microsoft Graph Command Line Tools" app, so no Azure
registration is needed. The token cache lives in `~/.config/mstodo-mcp/token_cache.json`
(mode 600) and refreshes itself. `mstodo-mcp logout` deletes it.

## Staying signed in

Access tokens last about an hour and are renewed silently. The refresh token behind them
expires after 90 days without use, or earlier if the Microsoft password changes or the
app's access is removed at https://account.live.com/consent/Manage.

```bash
.venv/bin/mstodo-mcp install-keepalive     # daily launchd job (10:00, and at login)
.venv/bin/mstodo-mcp uninstall-keepalive
```

The job runs `mstodo-mcp keepalive`, which renews the refresh token so the 90-day window
never runs out. If sign-in is really needed, it shows a dialog; "Sign in" copies the code,
opens the Microsoft page and saves the new token once you finish. "Later" (or no answer
within 4 hours) reminds again on the next run. Offline runs just retry next time.
Log: `~/Library/Logs/mstodo-mcp-keepalive.log`.

If a tool call finds the sign-in expired, the server starts a sign-in in the background and
returns the link and code (also shown as a macOS notification), so no terminal is needed.

## Tools

| Tool | What it does |
|---|---|
| `list_lists`, `create_list`, `rename_list`, `delete_list` | Lists |
| `list_tasks` | Tasks in a list: `status` open/completed/all, `title_contains`, `include_steps`, `limit` (newest first) |
| `get_task` | One task in full: note, steps (with tick times), dates, reminder (even when switched off), importance, repeat rule, linked emails, attachment names and sizes |
| `create_task`, `update_task`, `delete_task` | Title, note, due date, reminder, importance, completion; `create_task` can add steps |
| `add_step`, `update_step`, `delete_step` | Steps (subtasks) |

Lists can be named by display name (case-insensitive) or id. Dates are in the local
time zone: due dates `YYYY-MM-DD`, reminders `YYYY-MM-DD HH:MM`. In `update_task`,
`clear=["note" | "due_date" | "reminder"]` removes those fields.

Not supported yet: editing repeat rules, downloading or adding attachment files, and
"My Day" (not in the Graph API).

## Configuration (environment variables)

- `MSTODO_CLIENT_ID`: use your own Azure app registration instead of Microsoft's public one
- `MSTODO_AUTHORITY`: default `https://login.microsoftonline.com/consumers` (personal accounts); use `.../organizations` for work accounts
- `MSTODO_TIMEZONE`: IANA zone, default is the system zone
- `MSTODO_CACHE`: token cache path
