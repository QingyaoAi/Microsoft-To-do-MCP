# mstodo-mcp

MCP server for reading and editing Microsoft To Do through Microsoft Graph, plus an agent
skill that teaches any AI agent (Claude Code, Codex, Gemini, Cursor, ...) how to use it well.

There are two ways to run it: the **macOS menu-bar app** (no Python or terminal needed), or
**from source** on any OS with [uv](https://docs.astral.sh/uv/). Either way you need a
Microsoft account with To Do.

## macOS app

`To Do MCP.app` is a menu-bar app (macOS 13 or later) that bundles its own Python and the
server. From its menu you can:

- sign in to Microsoft (the code is copied and the Microsoft page opens for you), and see
  whether the sign-in is still valid; it renews the sign-in daily while running and notifies
  you if you need to sign in again
- **Connect to Agent**: register the server with Claude Code, Codex CLI, Claude Desktop,
  Cursor or Gemini CLI in one click (JSON config files keep their other settings, and a
  `.bak-todo-mcp` backup is written first)
- **Install Skill** for Claude Code or Codex (an existing, different copy is moved to
  `skill-backups/`, never deleted)
- turn on **Launch at Login**

Install: unzip, drag **To Do MCP** into Applications, and open it from there. The app isn't
signed by Apple yet, so the first time macOS will refuse to open it: go to System Settings →
Privacy & Security and click **Open Anyway** (or right-click the app → Open). Build it yourself
with `scripts/build-app.sh` (needs Swift, from Xcode or the Command Line Tools, and uv); the
result goes to `dist/`. Builds are for the building Mac's architecture.

Inside the app, `To Do MCP.app/Contents/MacOS/mstodo-mcp` is the same CLI and server as below
(`status`, `login`, ...), and the app's own binary has a scriptable mode:

```bash
APP="/Applications/To Do MCP.app/Contents/MacOS"
"$APP/ToDoMCP" --diagnose                    # what's connected and installed
"$APP/ToDoMCP" --connect codex               # claude-code, codex, claude-desktop, cursor, gemini
"$APP/ToDoMCP" --install-skill claude        # claude or codex; add --replace to overwrite
```

## Setup from source

```bash
git clone https://github.com/QingyaoAi/Microsoft-To-do-MCP.git
cd Microsoft-To-do-MCP
uv sync                       # install into .venv (Python 3.12, pinned by uv)
.venv/bin/mstodo-mcp login    # one-time device-code sign-in in the browser
.venv/bin/mstodo-mcp status   # check sign-in
```

### Connect it to your agent

The server is a local stdio program with no arguments: `<repo>/.venv/bin/mstodo-mcp`. Register
it under the name `mstodo` in whichever MCP client you use, for example:

```bash
# Claude Code
claude mcp add --scope user mstodo -- "$PWD/.venv/bin/mstodo-mcp"
# Codex CLI
codex mcp add mstodo -- "$PWD/.venv/bin/mstodo-mcp"
```

Clients configured with an `mcpServers` JSON file (Claude Desktop, Cursor, Gemini CLI and
others) take the same command:

```json
{
  "mcpServers": {
    "mstodo": { "command": "/absolute/path/to/repo/.venv/bin/mstodo-mcp" }
  }
}
```

### Install the skill (optional)

`skills/ms-todo/SKILL.md` teaches an agent to use the tools well: find tasks before editing,
ask when a name is ambiguous, handle dates, respect the limits, and cope with an expired
sign-in. It uses the open Agent Skills format (a folder with a `SKILL.md`), is written for any
MCP client, and doesn't assume Claude. Copy or symlink the folder into your agent's skills
directory, for example:

```bash
mkdir -p ~/.claude/skills && cp -r skills/ms-todo ~/.claude/skills/   # Claude Code
mkdir -p ~/.codex/skills && cp -r skills/ms-todo ~/.codex/skills/     # Codex CLI
```

For other agents, see their documentation for the skills directory. For an agent without
skill support, paste the body of `SKILL.md` (everything after the front matter) into its
instructions file, such as `AGENTS.md` or `GEMINI.md`.

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

## License

MIT, see [LICENSE](LICENSE).
