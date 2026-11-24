#!/usr/bin/env python3
"""Serves illustration image ids for a chapter the website no longer serves.

A delisted book keeps its catalogue but loses every reading page, so its illustration chapter
has no page to read the image URLs from. The relay still returns them, and the image host is
the same one the website uses, so the list is fetched once per chapter and stored under the
chapter id.

  GET /illust?aid=<aid>&cid=<cid>

A chapter with no pictures answers with an empty list, which is a valid and permanent answer —
the reply is stored either way, so a chapter is asked of the relay at most once.
"""

import base64
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("WK8_DB", "/opt/wk8illust/illust.db")
PORT = int(os.environ.get("WK8_PORT", "8080"))
RELAY_URL = "https://wenku8-relay.mewx.org/"
IMAGE_HOST = "https://pic.777743.xyz/"
UA = "okhttp/4.12.0"

APPVER_VERSION = "1.30"
APPVER_NAME = "digital-bento"
IMAGE_RE = re.compile(r"https://pic\.777743\.xyz/([0-9]+/[0-9]+/[0-9]+/[0-9]+\.jpg)")

_db_lock = threading.Lock()
_local = threading.local()

# Chapters currently being fetched, so a burst for one chapter makes one relay call.
_inflight = {}
_inflight_lock = threading.Lock()


def db():
    """One connection per thread; SQLite connections are not shareable across threads."""
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, timeout=30)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=10000")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS illustration ("
            " cid INTEGER PRIMARY KEY,"
            " aid INTEGER NOT NULL,"
            " paths TEXT NOT NULL,"
            " fetched_at INTEGER NOT NULL,"
            " source TEXT NOT NULL)"
        )
        conn.commit()
        _local.conn = conn
    return conn


def appver(now=None):
    """The relay's per-minute credential, matching the official client."""
    window = int(now if now is not None else time.time()) // 60
    digest = hmac.new(
        APPVER_NAME.encode(),
        f"{APPVER_VERSION}|{APPVER_NAME}|{window}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return f"{APPVER_VERSION}-{APPVER_NAME}-{digest[12:20]}"


def relay_chapter_images(aid, cid):
    """Asks the relay for one chapter's text and keeps the image addresses in it."""
    action = f"action=book&do=text&aid={aid}&cid={cid}&t=0"
    body = "&appver=%s&request=%s&timetoken=%d" % (
        appver(),
        base64.b64encode(action.encode()).decode(),
        int(time.time() * 1000),
    )
    request = urllib.request.Request(
        RELAY_URL,
        data=body.encode(),
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": UA,
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        text = response.read().decode("utf-8", "replace")
    return IMAGE_RE.findall(text)


def stored(cid):
    with _db_lock:
        row = db().execute(
            "SELECT aid, paths FROM illustration WHERE cid = ?", (cid,)
        ).fetchone()
    if row is None:
        return None
    return {"aid": row[0], "paths": json.loads(row[1]), "cached": True}


def store(aid, cid, paths, source):
    with _db_lock:
        db().execute(
            "INSERT OR REPLACE INTO illustration (cid, aid, paths, fetched_at, source)"
            " VALUES (?, ?, ?, ?, ?)",
            (cid, aid, json.dumps(paths), int(time.time()), source),
        )
        db().commit()


class Handler(BaseHTTPRequestHandler):
    server_version = "wk8illust/1"

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def do_POST(self):
        """Health checks from a monitor may use POST; answer the same as GET."""
        self.do_GET()

    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fetch(self, aid, cid):
        """Asks the relay once and stores the answer, empty included."""
        try:
            paths = relay_chapter_images(aid, cid)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            self._send(502, {"error": "relay unavailable: %s" % error})
            return None
        store(aid, cid, paths, "relay")
        return {"aid": aid, "paths": paths, "cached": False}

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send(200, {"ok": True})
            return
        if parsed.path != "/illust":
            self._send(404, {"error": "not found"})
            return

        query = parse_qs(parsed.query)
        try:
            aid = int(query.get("aid", [""])[0])
            cid = int(query.get("cid", [""])[0])
        except ValueError:
            self._send(400, {"error": "aid and cid must be integers"})
            return

        hit = stored(cid)
        if hit is None:
            # Wait for the first caller to finish rather than asking the relay as well.
            with _inflight_lock:
                gate = _inflight.setdefault(cid, threading.Lock())
            with gate:
                hit = stored(cid)
                if hit is None:
                    hit = self._fetch(aid, cid)
                    if hit is None:
                        return
                with _inflight_lock:
                    _inflight.pop(cid, None)
        if hit is not None:
            self._send(200, {
                "cid": cid,
                "aid": hit["aid"],
                "cached": hit["cached"],
                "images": [IMAGE_HOST + p for p in hit["paths"]],
            })
            return



def main():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("listening on :%d, db %s" % (PORT, DB_PATH), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
