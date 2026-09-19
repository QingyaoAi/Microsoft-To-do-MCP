"""Thin Microsoft Graph client for the To Do API, with retries and token refresh."""

import os
import time
from pathlib import Path

import httpx

from .auth import Auth

GRAPH_URL = "https://graph.microsoft.com/v1.0"
MAX_ATTEMPTS = 5


class GraphError(Exception):
    pass


def local_timezone() -> str:
    """IANA name of the local zone, e.g. 'Europe/Paris' (override with MSTODO_TIMEZONE)."""
    if tz := os.environ.get("MSTODO_TIMEZONE"):
        return tz
    try:
        target = str(Path("/etc/localtime").resolve())
        return target.split("zoneinfo/", 1)[1]
    except (OSError, IndexError):
        return "UTC"


class Graph:
    def __init__(self, auth: Auth, timezone: str) -> None:
        self._auth = auth
        self.timezone = timezone
        self._http = httpx.Client(base_url=GRAPH_URL, timeout=30)

    def request(self, method: str, path: str, *, params: dict | None = None, json: dict | None = None):
        refreshed = False
        for attempt in range(MAX_ATTEMPTS):
            headers = {
                "Authorization": f"Bearer {self._auth.token(force_refresh=refreshed)}",
                # Return date/time fields in the user's zone instead of UTC.
                "Prefer": f'outlook.timezone="{self.timezone}"',
            }
            try:
                r = self._http.request(method, path, params=params, json=json, headers=headers)
            except httpx.TransportError as e:
                if attempt == MAX_ATTEMPTS - 1:
                    raise GraphError(f"Network error talking to Microsoft Graph: {e}") from e
                time.sleep(2**attempt)
                continue
            if r.status_code == 401 and not refreshed:
                refreshed = True
                continue
            if r.status_code in (429, 500, 502, 503, 504) and attempt < MAX_ATTEMPTS - 1:
                time.sleep(min(float(r.headers.get("Retry-After", 2**attempt)), 60))
                continue
            break
        if r.status_code >= 400:
            try:
                err = r.json()["error"]
                detail = f"{err.get('code')}: {err.get('message')}"
            except (ValueError, KeyError):
                detail = r.text[:300]
            raise GraphError(f"Graph {method} {path} failed ({r.status_code}) {detail}")
        return None if r.status_code == 204 or not r.content else r.json()

    def get_all(self, path: str, params: dict | None = None, limit: int | None = None) -> list[dict]:
        """GET a collection, following @odata.nextLink; stops early once `limit` items are in."""
        items: list[dict] = []
        url: str | None = path
        while url:
            page = self.request("GET", url, params=params)
            items.extend(page.get("value", []))
            if limit is not None and len(items) >= limit:
                return items[:limit]
            url = page.get("@odata.nextLink")
            params = None  # nextLink already carries the query
        return items
