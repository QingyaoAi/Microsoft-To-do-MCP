"""Entry point: `mstodo-mcp` serves MCP over stdio; other commands manage sign-in."""

import os
import plistlib
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from . import notify
from .auth import Auth, AuthError, LoginRequired

USAGE = "usage: mstodo-mcp [serve|login|logout|status|keepalive|install-keepalive|uninstall-keepalive]"

LAUNCHD_LABEL = "com.mstodo-mcp.keepalive"
LAUNCHD_PLIST = Path.home() / "Library/LaunchAgents" / f"{LAUNCHD_LABEL}.plist"
KEEPALIVE_LOG = Path.home() / "Library/Logs/mstodo-mcp-keepalive.log"
KEEPALIVE_HOUR = 10  # daily run time (local); launchd also runs a missed run after wake
DIALOG_WAIT = 4 * 3600  # how long the reminder dialog waits for an answer


def log(message: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} {message}", flush=True)


def keepalive(auth: Auth) -> int:
    """Refresh the sign-in so it never lapses; if it already has, remind and re-sign-in."""
    try:
        auth.token(force_refresh=True)
    except LoginRequired as e:
        log(f"sign-in needed: {e}")
        return remind_and_login(auth)
    except Exception as e:  # offline, Microsoft outage, ...: try again on the next run
        log(f"refresh failed, will retry next run: {type(e).__name__}: {e}")
        return 1
    log(f"refreshed sign-in for {auth.username()}")
    return 0


def remind_and_login(auth: Auth) -> int:
    choice = notify.ask(
        "Your Microsoft To Do sign-in for Claude has expired.\n\n"
        "Sign in again now? It takes about a minute: the code is copied for you and "
        "the Microsoft page opens in your browser.",
        buttons=["Later", "Sign in"],
        default="Sign in",
        give_up_after=DIALOG_WAIT,
    )
    if choice != "Sign in":
        log("user postponed sign-in (reminding again on the next run)")
        return 2
    flow = auth.start_login()
    notify.copy(flow["user_code"])
    notify.open_url(flow["verification_uri"])
    notify.show(
        f"Paste the code {flow['user_code']} (already copied) into the Microsoft page that "
        "just opened, then sign in and accept.",
        give_up_after=int(flow["expires_in"]),
    )
    try:
        user = auth.finish_login(flow)
    except AuthError as e:
        log(f"sign-in did not complete: {e}")
        notify.notify("Sign-in didn't finish. I'll remind you again tomorrow.")
        return 2
    log(f"signed in again as {user}")
    notify.notify(f"Signed in again as {user}. Microsoft To Do is connected.")
    return 0


def install_keepalive() -> None:
    exe = os.path.abspath(sys.argv[0])
    env = {k: v for k, v in os.environ.items() if k.startswith("MSTODO_")}
    plist = {
        "Label": LAUNCHD_LABEL,
        "ProgramArguments": [exe, "keepalive"],
        "StartCalendarInterval": {"Hour": KEEPALIVE_HOUR, "Minute": 0},
        "RunAtLoad": True,
        "StandardOutPath": str(KEEPALIVE_LOG),
        "StandardErrorPath": str(KEEPALIVE_LOG),
        **({"EnvironmentVariables": env} if env else {}),
    }
    LAUNCHD_PLIST.parent.mkdir(parents=True, exist_ok=True)
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", domain, str(LAUNCHD_PLIST)], capture_output=True)
    with open(LAUNCHD_PLIST, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["launchctl", "bootstrap", domain, str(LAUNCHD_PLIST)], check=True)
    print(f"Installed {LAUNCHD_PLIST}\nRuns daily at {KEEPALIVE_HOUR}:00 and at login; log: {KEEPALIVE_LOG}")


def uninstall_keepalive() -> None:
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(LAUNCHD_PLIST)], capture_output=True)
    LAUNCHD_PLIST.unlink(missing_ok=True)
    print("Removed the daily sign-in keep-alive.")


def main() -> None:
    command = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if command == "serve":
        from .server import mcp

        mcp.run("stdio")
        return
    if command == "install-keepalive":
        install_keepalive()
        return
    if command == "uninstall-keepalive":
        uninstall_keepalive()
        return

    auth = Auth()
    try:
        if command == "login":
            user = auth.login(show=lambda msg: print(msg, flush=True))
            print(f"Signed in as {user}. Token cache: {auth.cache_path}")
        elif command == "logout":
            auth.logout()
            print("Signed out.")
        elif command == "status":
            user = auth.username()
            if not user:
                sys.exit("Not signed in.")
            auth.token()
            print(f"Signed in as {user}; token OK.")
        elif command == "keepalive":
            sys.exit(keepalive(auth))
        else:
            sys.exit(USAGE)
    except AuthError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
