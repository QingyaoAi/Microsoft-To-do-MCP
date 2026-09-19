"""macOS user-facing helpers (notification, dialog, clipboard, browser) via built-in tools."""

import json
import subprocess

TITLE = "Microsoft To Do for Claude"


def _osascript(script: str, wait: bool = True, timeout: float | None = None) -> str:
    if not wait:
        subprocess.Popen(["osascript", "-e", script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return ""
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return result.stdout.strip()


def _q(text: str) -> str:
    """AppleScript string literal (JSON escaping of quotes/backslashes/newlines is compatible)."""
    return json.dumps(text)


def notify(message: str) -> None:
    _osascript(f"display notification {_q(message)} with title {_q(TITLE)}", wait=False)


def ask(message: str, buttons: list[str], default: str, give_up_after: int) -> str | None:
    """Show a dialog; return the clicked button, or None if it timed out or was dismissed."""
    script = (
        f"display dialog {_q(message)} with title {_q(TITLE)} "
        f"buttons {{{', '.join(_q(b) for b in buttons)}}} default button {_q(default)} "
        f"with icon caution giving up after {give_up_after}"
    )
    try:
        out = _osascript(script, timeout=give_up_after + 30)
    except subprocess.TimeoutExpired:
        return None
    if "gave up:true" in out or "button returned:" not in out:
        return None
    return out.split("button returned:", 1)[1].split(",", 1)[0]


def show(message: str, give_up_after: int) -> None:
    """Non-blocking informational dialog."""
    script = (
        f"display dialog {_q(message)} with title {_q(TITLE)} buttons {{\"OK\"}} "
        f"default button \"OK\" giving up after {give_up_after}"
    )
    _osascript(script, wait=False)


def copy(text: str) -> None:
    subprocess.run(["pbcopy"], input=text, text=True, check=False)


def open_url(url: str) -> None:
    subprocess.run(["open", url], check=False)
