---
name: ms-todo
description: Read and edit the user's Microsoft To Do (lists, tasks, steps/subtasks, notes, due dates, reminders, importance, marking done) through the `mstodo` MCP server. Use this whenever the user mentions Microsoft To Do, To Do app, their to-do lists or tasks, wants to add/find/finish/delete/reschedule a task, see what's open or finished, or check a task's subtasks — including Chinese requests like 待办、任务、子任务、完成、删除任务 — even if they don't name the app. Not for macOS Reminders, which is a different app.
---

# Microsoft To Do via the `mstodo` MCP server

The `mstodo` server talks to Microsoft Graph as the signed-in user. Changes sync to the
To Do app, website and phone, so every write is real and visible everywhere.

## Getting the tools

The tools are `mcp__mstodo__<name>` and are often deferred. If they aren't callable yet, load
the ones you need first, e.g. `ToolSearch("select:mcp__mstodo__list_tasks,mcp__mstodo__update_task")`.

| Tool | Use it to |
|---|---|
| `list_lists` | See list names (do this when unsure what a list is called) |
| `list_tasks(list, status, title_contains, include_steps, limit)` | Find tasks; newest first |
| `get_task(list, task_id)` | Everything about one task: full note, steps, dates, repeat, links, attachments |
| `create_task(list, title, note, due_date, reminder, important, steps)` | Add a task, optionally with steps |
| `update_task(list, task_id, title, note, due_date, reminder, important, completed, clear)` | Change only the fields passed; `clear` removes fields |
| `delete_task(list, task_id)` | Delete permanently |
| `add_step` / `update_step` / `delete_step` | Subtasks ("steps" in To Do) |
| `create_list` / `rename_list` / `delete_list` | Lists (deleting a list deletes all its tasks) |

## How to work

**Resolve the list.** `list` takes the exact display name (case-insensitive) or an id, so map
the user's words to a real list name (e.g. "my work list" might be `Work` or `Work-ToDo`).
Call `list_lists` rather than guessing when the mapping isn't obvious. The default list is
usually `Tasks`.

**Find the task before changing it.** Edits need a `task_id`, which only comes from
`list_tasks`. Use `title_contains` to narrow it down, and pick `status` deliberately:
the default is `open`, so a finished task is invisible unless you pass `completed` or `all`.
If you don't know which list a task is in, search the likely lists (or all of them) with
`title_contains`. Lists can hold thousands of finished tasks, so filter or use `limit`
rather than paging through everything.

**When a search matches several tasks, ask which one** before editing or deleting — a wrong
guess changes the user's real data. When it matches exactly one, just proceed.

**Deleting is permanent** (the API has no recycle bin). If the user explicitly asked to delete
a specific task, do it; for bulk deletes or anything inferred, confirm first. Prefer marking a
task finished when the user says "done", "finished", "完成", "划掉".

**Mark finished / reopen:** `update_task(completed=true)` / `completed=false`. To Do records the
completion date itself.

## Dates, times and fields

- Dates and times are in the time zone named in the server's instructions (the machine's
  local zone). Turn relative dates ("Friday", "明天", "next week") into absolute ones using
  today's date.
- `due_date` is `YYYY-MM-DD` (To Do due dates have no time). `reminder` is
  `YYYY-MM-DD HH:MM` local time.
- To remove a note, due date or reminder, pass `clear`, e.g.
  `update_task(..., due_date="2026-10-08", clear=["reminder"])`. Leave out any field you
  aren't changing rather than sending it empty.
- `important=true` is the To Do star. In results, importance appears as
  `"importance": "high"` (star) or `"low"`; absent means normal.
- `reminder_on: false` means a reminder time is stored but switched off.
- `completed_on` is a date; `repeat` shows the repeat rule; `links` are usually Outlook emails.

## Limits (say so rather than improvising)

- Repeat rules can be read but not created or changed.
- Attachments: names and sizes only; files can't be downloaded or added.
- "My Day" isn't available through the API.
- `Flagged Emails` holds tasks made from flagged Outlook emails; read it, but add new tasks to
  a normal list.

## Reporting back

Confirm what changed in plain words — task title, list, and the dates or steps you set — for
example "Added 'Submit review' to Work, due 2026-10-03, starred." Don't show task ids unless
asked. When listing tasks, show titles with due dates/steps rather than raw JSON.

## If something goes wrong

- **Sign-in expired:** the tool error contains a link and a code. Pass both to the user
  exactly, wait for them to say they've signed in, then retry the same call.
- **Tools missing or not connected:** check with `claude mcp get mstodo`. In the server's
  folder, `.venv/bin/mstodo-mcp status` checks the sign-in and `.venv/bin/mstodo-mcp login`
  signs in again from a terminal.
- **Graph errors** (e.g. `ErrorItemNotFound`) usually mean a stale id: search again with
  `list_tasks` and retry once.
