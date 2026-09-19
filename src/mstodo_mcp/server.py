"""MCP tools for reading and editing Microsoft To Do lists, tasks and steps."""

import functools
import html
import json
import logging
import re
import threading
import time
from datetime import date, datetime, timezone
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations
from pydantic import Field

from . import notify
from .auth import Auth, AuthError, LoginRequired
from .graph import Graph, GraphError, local_timezone

logging.getLogger("httpx").setLevel(logging.WARNING)  # no per-request log lines

auth = Auth()
graph = Graph(auth, local_timezone())
TZ = ZoneInfo(graph.timezone)
NOTE_PREVIEW = 200
LISTS_TTL = 300  # seconds to reuse the list-name -> id lookup

# Sent to every MCP client when it connects, so these rules reach any agent, whether or not
# it has loaded the ms-todo skill. Keep them short; the skill has the longer version.
INSTRUCTIONS = f"""\
Read and edit the user's Microsoft To Do. Every change is real and syncs to all their devices.
- Lists: pass the exact display name (case-insensitive) or id; call list_lists if unsure.
- Find before editing: task ids come only from list_tasks. Its default status is "open", so
  finished tasks are hidden unless you pass status="completed" or "all". Use title_contains.
- If a search matches several tasks, ask the user which one. If nobody can answer (unattended
  run), change nothing and report the candidates.
- delete_task and delete_list are permanent (no recycle bin). Delete only what the user clearly
  asked for; when the user says a task is done, mark it with update_task(completed=true).
- Dates and times are in {graph.timezone}: due_date YYYY-MM-DD, reminder YYYY-MM-DD HH:MM.
  Convert relative dates ("Friday", "明天") to absolute ones. Remove fields with
  update_task(clear=["reminder"]) (or "note", "due_date"), never by sending empty values.
- Steps are To Do's subtasks. important=true is the star; results show "importance".
- Not possible: changing repeat rules, downloading/adding attachments, "My Day".
- If a tool error says sign-in has expired, give the user the link and code from the error,
  wait for them to finish, then retry.
- Tell the user what changed in plain words (title, list, dates); don't show ids unless asked.
"""

mcp = MCPServer("mstodo", instructions=INSTRUCTIONS)

READ = ToolAnnotations(read_only_hint=True, open_world_hint=True)
ADD = ToolAnnotations(read_only_hint=False, destructive_hint=False, open_world_hint=True)
CHANGE = ToolAnnotations(read_only_hint=False, destructive_hint=True, idempotent_hint=True, open_world_hint=True)

ListRef = Annotated[str, Field(description="List display name (case-insensitive) or list id")]
TaskId = Annotated[str, Field(description="Task id from list_tasks")]


def tool(annotations: ToolAnnotations):
    """Register a tool that returns compact JSON text and turns expected failures into
    messages the model can read. (The SDK would otherwise pretty-print results.)"""

    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            try:
                result = fn(*args, **kwargs)
            except LoginRequired as e:
                raise ToolError(_sign_in_prompt()) from e
            except (AuthError, GraphError, ValueError) as e:
                raise ToolError(str(e)) from e
            return json.dumps(result, ensure_ascii=False, separators=(",", ":"))

        return mcp.tool(annotations=annotations, structured_output=False)(wrapper)

    return decorator


def _sign_in_prompt() -> str:
    """Start (or reuse) a background sign-in and tell the model what the user must do."""

    def done(user: str | None) -> None:
        if user:
            notify.notify(f"Signed in again as {user}. Microsoft To Do is connected.")

    try:
        flow = auth.login_in_background(on_done=done)
    except Exception as e:  # e.g. offline: cannot even start a sign-in
        return f"Microsoft To Do sign-in has expired, and a new sign-in could not be started: {e}"
    notify.notify(f"Sign-in needed: open {flow['verification_uri']} and enter code {flow['user_code']}")
    return (
        "Microsoft To Do sign-in has expired. Ask the user to open "
        f"{flow['verification_uri']} and enter the code {flow['user_code']} (valid for about "
        f"{max(1, int(flow['expires_at'] - time.time()) // 60)} minutes), sign in as their Microsoft "
        "account and accept. The new sign-in is saved automatically; retry this tool afterwards."
    )


# ---- lists ---------------------------------------------------------------------------

_lists_cache: tuple[float, list[dict]] = (0.0, [])
_lists_lock = threading.Lock()


def _lists(refresh: bool = False) -> list[dict]:
    global _lists_cache
    with _lists_lock:
        fetched_at, lists = _lists_cache
        if refresh or time.monotonic() - fetched_at > LISTS_TTL:
            lists = graph.get_all("/me/todo/lists")
            _lists_cache = (time.monotonic(), lists)
        return lists


def _list_id(ref: str) -> str:
    for refresh in (False, True):
        lists = _lists(refresh)
        if any(l["id"] == ref for l in lists):
            return ref
        matches = [l for l in lists if l["displayName"].casefold() == ref.strip().casefold()]
        if len(matches) > 1:
            raise ValueError(f"More than one list is named {ref!r}; pass its id instead.")
        if matches:
            return matches[0]["id"]
    raise ValueError(f"No list named {ref!r}. Call list_lists to see the names.")


def _task_path(list_ref: str, task_id: str = "") -> str:
    path = f"/me/todo/lists/{_list_id(list_ref)}/tasks"
    return f"{path}/{task_id}" if task_id else path


def _fmt_list(l: dict) -> dict:
    out = {"id": l["id"], "name": l["displayName"]}
    if l.get("wellknownListName") not in (None, "none"):
        out["kind"] = l["wellknownListName"]
    if l.get("isShared"):
        out["shared"] = True
    return out


# ---- formatting ----------------------------------------------------------------------


def _fmt_dtz(value: dict | None, date_only: bool = False) -> str | None:
    """Format a Graph dateTimeTimeZone in the user's zone."""
    if not value or not value.get("dateTime"):
        return None
    moment = datetime.fromisoformat(value["dateTime"][:19])
    zone = value.get("timeZone") or "UTC"
    if zone != graph.timezone:
        try:
            moment = moment.replace(tzinfo=ZoneInfo(zone)).astimezone(TZ)
        except (KeyError, ValueError):
            return f"{moment:%Y-%m-%d %H:%M} ({zone})"
    return moment.strftime("%Y-%m-%d" if date_only else "%Y-%m-%d %H:%M")


def _fmt_utc(value: str | None) -> str | None:
    if not value:
        return None
    moment = datetime.fromisoformat(value[:19]).replace(tzinfo=timezone.utc)
    return moment.astimezone(TZ).strftime("%Y-%m-%d %H:%M")


def _note_text(body: dict | None) -> str:
    body = body or {}
    text = body.get("content") or ""
    if body.get("contentType") == "html":
        text = html.unescape(re.sub(r"<[^>]+>", "", re.sub(r"(?i)<br\s*/?>|</p>", "\n", text)))
    return text.strip()


def _fmt_repeat(recurrence: dict | None) -> dict | None:
    if not recurrence or not recurrence.get("pattern"):
        return None
    pattern, rng = recurrence["pattern"], recurrence.get("range") or {}
    kind = pattern.get("type", "")
    out = {k: v for k, v in pattern.items() if v and k not in ("firstDayOfWeek", "index")}
    if kind.startswith("relative"):  # e.g. "second Tuesday of the month"
        out["index"] = pattern.get("index")
    if rng.get("startDate"):
        out["starts"] = rng["startDate"]
    if rng.get("type") == "endDate":
        out["ends"] = rng.get("endDate")
    elif rng.get("type") == "numbered":
        out["occurrences"] = rng.get("numberOfOccurrences")
    return out


def _fmt_task(t: dict, full: bool = False) -> dict:
    out: dict = {"id": t["id"], "title": t.get("title", ""), "completed": t.get("status") == "completed"}
    if t.get("status") not in ("notStarted", "completed"):
        out["status"] = t["status"]
    if t.get("importance", "normal") != "normal":
        out["importance"] = t["importance"]  # "high" is the To Do star
    if start := _fmt_dtz(t.get("startDateTime"), date_only=True):
        out["start"] = start
    if due := _fmt_dtz(t.get("dueDateTime"), date_only=True):
        out["due"] = due
    if reminder := _fmt_dtz(t.get("reminderDateTime")):
        out["reminder"] = reminder
        if not t.get("isReminderOn"):
            out["reminder_on"] = False
    if done := _fmt_dtz(t.get("completedDateTime"), date_only=True):
        out["completed_on"] = done
    if repeat := _fmt_repeat(t.get("recurrence")):
        out["repeat"] = repeat
    if note := _note_text(t.get("body")):
        out["note"] = note if full or len(note) <= NOTE_PREVIEW else note[:NOTE_PREVIEW] + "…"
    if t.get("categories"):
        out["categories"] = t["categories"]
    if "checklistItems" in t:
        out["steps"] = [_fmt_step(s, full) for s in t["checklistItems"]]
    if t.get("linkedResources"):
        out["links"] = [
            {"title": r.get("displayName"), "url": r.get("webUrl"), "app": r.get("applicationName")}
            for r in t["linkedResources"]
        ]
    if "attachments" in t:
        out["attachments"] = [
            {"name": a.get("name"), "type": a.get("contentType"), "bytes": a.get("size")} for a in t["attachments"]
        ]
    elif t.get("hasAttachments"):
        out["has_attachments"] = True
    if full:
        out["created"] = _fmt_utc(t.get("createdDateTime"))
        out["modified"] = _fmt_utc(t.get("lastModifiedDateTime"))
    return out


def _fmt_step(s: dict, full: bool = False) -> dict:
    out = {"id": s["id"], "text": s.get("displayName", ""), "checked": bool(s.get("isChecked"))}
    if full:
        if checked_at := _fmt_utc(s.get("checkedDateTime")):
            out["checked_at"] = checked_at
        out["created"] = _fmt_utc(s.get("createdDateTime"))
    return out


# ---- input parsing -------------------------------------------------------------------


def _due_value(value: str) -> dict | None:
    if not value:
        return None
    try:
        day = date.fromisoformat(value.strip())
    except ValueError:
        raise ValueError(f"due_date must look like 2026-09-30, got {value!r}.") from None
    return {"dateTime": f"{day.isoformat()}T00:00:00", "timeZone": graph.timezone}


def _reminder_value(value: str) -> dict | None:
    if not value:
        return None
    try:
        moment = datetime.fromisoformat(value.strip().replace(" ", "T"))
    except ValueError:
        raise ValueError(f"reminder must look like 2026-09-30 09:00, got {value!r}.") from None
    return {"dateTime": moment.strftime("%Y-%m-%dT%H:%M:00"), "timeZone": graph.timezone}


def _apply_fields(
    body: dict,
    *,
    note: str | None,
    due_date: str | None,
    reminder: str | None,
    important: bool | None,
) -> None:
    if note is not None:
        body["body"] = {"content": note, "contentType": "text"}
    if due_date is not None:
        body["dueDateTime"] = _due_value(due_date)
    if reminder is not None:
        body["reminderDateTime"] = _reminder_value(reminder)
        body["isReminderOn"] = bool(reminder)
    if important is not None:
        body["importance"] = "high" if important else "normal"


# ---- list tools ----------------------------------------------------------------------


@tool(READ)
def list_lists() -> list[dict]:
    """List all To Do lists (including the default 'Tasks' list and 'Flagged Emails')."""
    return [_fmt_list(l) for l in _lists(refresh=True)]


@tool(ADD)
def create_list(name: Annotated[str, Field(description="Name of the new list")]) -> dict:
    """Create a new To Do list."""
    created = graph.request("POST", "/me/todo/lists", json={"displayName": name})
    _lists(refresh=True)
    return _fmt_list(created)


@tool(CHANGE)
def rename_list(list: ListRef, new_name: str) -> dict:
    """Rename a To Do list."""
    updated = graph.request("PATCH", f"/me/todo/lists/{_list_id(list)}", json={"displayName": new_name})
    _lists(refresh=True)
    return _fmt_list(updated)


@tool(CHANGE)
def delete_list(list: ListRef) -> dict:
    """Permanently delete a To Do list and every task in it (no recycle bin). Confirm with the user first."""
    list_id = _list_id(list)
    graph.request("DELETE", f"/me/todo/lists/{list_id}")
    _lists(refresh=True)
    return {"deleted_list": list}


# ---- task tools ----------------------------------------------------------------------


@tool(READ)
def list_tasks(
    list: ListRef,
    status: Annotated[Literal["open", "completed", "all"], Field(description="Which tasks to return")] = "open",
    title_contains: Annotated[str | None, Field(description="Only tasks whose title contains this text")] = None,
    include_steps: Annotated[bool, Field(description="Include each task's steps (subtasks)")] = False,
    limit: Annotated[int, Field(ge=1, le=5000, description="Maximum tasks to return, newest first")] = 100,
) -> dict:
    """List tasks in a list, newest first. Finished tasks are hidden unless status is "completed" or "all".
    Notes longer than 200 characters are shortened; use get_task for the full task."""
    params = {"$top": "100", "$orderby": "createdDateTime desc"}
    if status == "open":
        params["$filter"] = "status ne 'completed'"
    elif status == "completed":
        params["$filter"] = "status eq 'completed'"
    if include_steps:
        params["$expand"] = "checklistItems"
    # Graph's contains() on title is unreliable, so filter locally when asked.
    fetch_limit = None if title_contains else limit + 1
    tasks = graph.get_all(_task_path(list), params=params, limit=fetch_limit)
    if title_contains:
        needle = title_contains.casefold()
        tasks = [t for t in tasks if needle in t.get("title", "").casefold()]
    return {
        "count": min(len(tasks), limit),
        "truncated": len(tasks) > limit,
        "tasks": [_fmt_task(t) for t in tasks[:limit]],
    }


@tool(READ)
def get_task(list: ListRef, task_id: TaskId) -> dict:
    """Get one task in full: note, steps, dates, repeat rule, linked items and attachment names."""
    path = _task_path(list, task_id)
    task = graph.request("GET", path, params={"$expand": "checklistItems,linkedResources"})
    if task.get("hasAttachments"):
        # Metadata only; the file bytes are not fetched.
        task["attachments"] = graph.get_all(f"{path}/attachments", params={"$select": "id,name,contentType,size"})
    return _fmt_task(task, full=True)


@tool(ADD)
def create_task(
    list: ListRef,
    title: str,
    note: Annotated[str | None, Field(description="Plain-text note")] = None,
    due_date: Annotated[str | None, Field(description="YYYY-MM-DD")] = None,
    reminder: Annotated[str | None, Field(description="YYYY-MM-DD HH:MM, local time")] = None,
    important: bool | None = None,
    steps: Annotated[list[str] | None, Field(description="Step (subtask) texts, in order")] = None,
) -> dict:
    """Create a task, optionally with a note, due date, reminder and steps."""
    body: dict = {"title": title}
    _apply_fields(body, note=note, due_date=due_date, reminder=reminder, important=important)
    path = _task_path(list)
    task = graph.request("POST", path, json=body)
    if steps:
        task["checklistItems"] = [
            graph.request("POST", f"{path}/{task['id']}/checklistItems", json={"displayName": text})
            for text in steps
        ]
    return _fmt_task(task, full=True)


@tool(CHANGE)
def update_task(
    list: ListRef,
    task_id: TaskId,
    title: str | None = None,
    note: Annotated[str | None, Field(description="New note")] = None,
    due_date: Annotated[str | None, Field(description="New due date, YYYY-MM-DD")] = None,
    reminder: Annotated[str | None, Field(description="New reminder, YYYY-MM-DD HH:MM")] = None,
    important: bool | None = None,
    completed: Annotated[bool | None, Field(description="true marks done, false reopens")] = None,
    clear: Annotated[
        list[Literal["note", "due_date", "reminder"]] | None,
        Field(description='Fields to remove from the task, e.g. ["reminder"]'),
    ] = None,
) -> dict:
    """Change a task. Only the fields you pass are changed; use `clear` to remove a note, due date or reminder."""
    clear = set(clear or [])
    new_values = {"note": note, "due_date": due_date, "reminder": reminder}
    if both := [name for name in clear if new_values[name]]:
        raise ValueError(f"{', '.join(both)} given both a new value and in `clear`; pass only one.")
    # _apply_fields treats "" as "remove" (still accepted directly, for older callers).
    note = "" if "note" in clear else note
    due_date = "" if "due_date" in clear else due_date
    reminder = "" if "reminder" in clear else reminder
    body: dict = {}
    if title is not None:
        body["title"] = title
    _apply_fields(body, note=note, due_date=due_date, reminder=reminder, important=important)
    if completed is not None:
        body["status"] = "completed" if completed else "notStarted"
    if not body:
        raise ValueError("Nothing to update: pass at least one field to change.")
    return _fmt_task(graph.request("PATCH", _task_path(list, task_id), json=body), full=True)


@tool(CHANGE)
def delete_task(list: ListRef, task_id: TaskId) -> dict:
    """Permanently delete a task (no recycle bin). To finish a task, use update_task(completed=true) instead."""
    graph.request("DELETE", _task_path(list, task_id))
    return {"deleted_task": task_id}


# ---- step (subtask) tools ------------------------------------------------------------


@tool(ADD)
def add_step(list: ListRef, task_id: TaskId, text: str, checked: bool = False) -> dict:
    """Add a step (subtask) to a task."""
    step = graph.request(
        "POST",
        f"{_task_path(list, task_id)}/checklistItems",
        json={"displayName": text, "isChecked": checked},
    )
    return _fmt_step(step)


@tool(CHANGE)
def update_step(
    list: ListRef,
    task_id: TaskId,
    step_id: Annotated[str, Field(description="Step id from get_task")],
    text: str | None = None,
    checked: bool | None = None,
) -> dict:
    """Rename a step or tick/untick it."""
    body: dict = {}
    if text is not None:
        body["displayName"] = text
    if checked is not None:
        body["isChecked"] = checked
    if not body:
        raise ValueError("Nothing to update: pass text and/or checked.")
    step = graph.request("PATCH", f"{_task_path(list, task_id)}/checklistItems/{step_id}", json=body)
    return _fmt_step(step)


@tool(CHANGE)
def delete_step(
    list: ListRef,
    task_id: TaskId,
    step_id: Annotated[str, Field(description="Step id from get_task")],
) -> dict:
    """Delete a step from a task."""
    graph.request("DELETE", f"{_task_path(list, task_id)}/checklistItems/{step_id}")
    return {"deleted_step": step_id}
