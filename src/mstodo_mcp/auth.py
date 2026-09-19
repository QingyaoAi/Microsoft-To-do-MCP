"""Microsoft sign-in (device code flow) with an on-disk MSAL token cache."""

import os
import threading
import time
from pathlib import Path

import msal
import requests  # MSAL's HTTP library

# Microsoft's own public "Microsoft Graph Command Line Tools" app. It accepts personal
# accounts and the device code flow, so no Azure app registration is needed.
DEFAULT_CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
DEFAULT_AUTHORITY = "https://login.microsoftonline.com/consumers"
DEFAULT_CACHE = "~/.config/mstodo-mcp/token_cache.json"
# MSAL adds offline_access (refresh token) itself and rejects it if listed here.
SCOPES = ["Tasks.ReadWrite"]

NOT_SIGNED_IN = "Not signed in to Microsoft To Do. Run `mstodo-mcp login` in a terminal first."
# Token-endpoint errors that only an interactive sign-in can fix (expired/revoked refresh token).
LOGIN_REQUIRED_ERRORS = {"invalid_grant", "interaction_required", "login_required", "consent_required"}


class AuthError(Exception):
    pass


class LoginRequired(AuthError):
    """The saved sign-in is missing, expired or revoked; the user has to sign in again."""


class Auth:
    def __init__(self) -> None:
        self.client_id = os.environ.get("MSTODO_CLIENT_ID", DEFAULT_CLIENT_ID)
        self.authority = os.environ.get("MSTODO_AUTHORITY", DEFAULT_AUTHORITY)
        self.cache_path = Path(os.environ.get("MSTODO_CACHE", DEFAULT_CACHE)).expanduser()
        self._lock = threading.Lock()
        self._pending_flow: dict | None = None
        self._cache = msal.SerializableTokenCache()
        self._cache_mtime = 0.0
        self._load()
        self._app = msal.PublicClientApplication(
            self.client_id, authority=self.authority, token_cache=self._cache
        )

    def _load(self) -> None:
        """(Re)load the cache if another process (e.g. `login`) rewrote the file."""
        try:
            mtime = self.cache_path.stat().st_mtime
        except FileNotFoundError:
            return
        if mtime != self._cache_mtime:
            self._cache.deserialize(self.cache_path.read_text())
            self._cache_mtime = mtime

    def _save(self) -> None:
        if not self._cache.has_state_changed:
            return
        self.cache_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        tmp = self.cache_path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(self._cache.serialize())
        os.replace(tmp, self.cache_path)
        self._cache.has_state_changed = False
        self._cache_mtime = self.cache_path.stat().st_mtime

    def _account(self) -> dict:
        accounts = self._app.get_accounts()
        if not accounts:
            raise LoginRequired(NOT_SIGNED_IN)
        return accounts[0]

    def token(self, force_refresh: bool = False) -> str:
        """Return a valid access token, refreshing it silently when needed.

        Raises LoginRequired when only a new interactive sign-in can help, and AuthError for
        other failures such as being offline (usually transient).
        """
        with self._lock:
            self._load()
            try:
                result = self._app.acquire_token_silent_with_error(
                    SCOPES, account=self._account(), force_refresh=force_refresh
                )
            except requests.RequestException as e:
                raise AuthError(f"Network error while refreshing the Microsoft sign-in: {e}") from e
            self._save()
        if result and "access_token" in result:
            return result["access_token"]
        error = (result or {}).get("error")
        detail = (result or {}).get("error_description", "")
        if result is None or error in LOGIN_REQUIRED_ERRORS:
            raise LoginRequired(f"Microsoft To Do sign-in has expired or was revoked. {detail}".strip())
        raise AuthError(f"Could not refresh the Microsoft sign-in ({error}): {detail}")

    def username(self) -> str | None:
        with self._lock:
            self._load()
            accounts = self._app.get_accounts()
        return accounts[0].get("username") if accounts else None

    def start_login(self) -> dict:
        """Begin a device code sign-in. The returned flow has `verification_uri`,
        `user_code`, `message` and `expires_at`; pass it to finish_login()."""
        with self._lock:
            flow = self._app.initiate_device_flow(scopes=SCOPES)
        if "user_code" not in flow:
            raise AuthError(flow.get("error_description", "Could not start sign-in."))
        return flow

    def finish_login(self, flow: dict) -> str:
        """Wait (up to ~15 minutes) for the user to finish signing in; returns the username.
        The lock is not held while waiting, so token() keeps working meanwhile."""
        result = self._app.acquire_token_by_device_flow(flow)
        with self._lock:
            self._save()
        if "access_token" not in result:
            raise AuthError(result.get("error_description", "Sign-in did not complete."))
        return result.get("id_token_claims", {}).get("preferred_username", "")

    def login(self, show=print) -> str:
        """Interactive device code sign-in; blocks until the user finishes in a browser."""
        flow = self.start_login()
        show(flow["message"])
        return self.finish_login(flow)

    def login_in_background(self, on_done=None) -> dict:
        """Start a sign-in whose completion is awaited on a daemon thread, reusing one that
        is still pending. `on_done(username_or_None)` runs when it finishes."""
        with self._lock:
            pending = self._pending_flow
            if pending and pending["expires_at"] - time.time() > 60:
                return pending
        flow = self.start_login()

        def wait() -> None:
            try:
                user = self.finish_login(flow)
            except AuthError:
                user = None
            with self._lock:
                if self._pending_flow is flow:
                    self._pending_flow = None
            if on_done:
                on_done(user)

        with self._lock:
            self._pending_flow = flow
        threading.Thread(target=wait, name="mstodo-login", daemon=True).start()
        return flow

    def logout(self) -> None:
        with self._lock:
            for account in self._app.get_accounts():
                self._app.remove_account(account)
            self.cache_path.unlink(missing_ok=True)
            self._cache_mtime = 0.0
