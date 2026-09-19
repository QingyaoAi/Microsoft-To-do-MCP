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

### Install

Requirements: macOS 13 or later on an Apple Silicon Mac (M1 or newer).

1. Download the `.dmg` from [Releases](https://github.com/QingyaoAi/Microsoft-To-do-MCP/releases),
   open it, and drag **To Do MCP** onto the Applications shortcut.
2. Open it **from Applications** (not from the disk image or Downloads; otherwise macOS runs
   it from a temporary location and connected agents lose track of it).
3. The first time, macOS blocks it (see below). After that, click the checklist icon in the
   menu bar → **Sign In…**, then **Connect to Agent**.

### "Apple could not verify…": opening an unsigned app

The app is free and open source but **not signed or notarized by Apple** (that needs a paid
Apple developer account), so Gatekeeper blocks the first launch. Only allow it if you
downloaded it from this repository's Releases page, or built it yourself.

- **In System Settings:** double-click the app and click **Done** when macOS refuses. Then
  open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**
  next to the "To Do MCP" message, confirm with your password or Touch ID, and click
  **Open Anyway** again. You only do this once. (On macOS 15 and later, right-click → Open no
  longer skips this step.)
- **Or in Terminal:** remove the "downloaded from the internet" flag, then open it normally:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/To Do MCP.app"
  ```

The same instructions are in `READ ME FIRST.txt` on the disk image. The app is ad-hoc signed,
so macOS can still check that its files haven't been changed since it was built.

### Build it yourself

`scripts/build-app.sh` builds the app and the `.dmg` into `dist/` (needs Swift, from Xcode or
the Command Line Tools, and uv). A build is for the building Mac's architecture, and an app
you build yourself isn't quarantined, so it opens without the steps above.

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
