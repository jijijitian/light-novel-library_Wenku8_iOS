#!/usr/bin/env python3
"""Minimal client for the legacy Wenku8 relay API."""
import base64, hashlib, hmac, time, urllib.parse, urllib.request, sys

BASE = "https://wenku8-relay.mewx.org/"

def appver():
    minutes = int(time.time()) // 60
    msg = f"1.30|digital-bento|{minutes}".encode()
    digest = hmac.new(b"digital-bento", msg, hashlib.sha256).hexdigest()
    return "1.30-digital-bento-" + digest[12:20]

def call(action, timeout=25):
    payload = base64.b64encode(action.encode()).decode()
    body = urllib.parse.urlencode({
        "request": payload,
        "appver": appver(),
        "timetoken": int(time.time() * 1000),
    }).encode()
    req = urllib.request.Request(BASE, data=body)
    req.add_header("User-Agent", "okhttp/4.12.0")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")

if __name__ == "__main__":
    status, text = call(sys.argv[1] if len(sys.argv) > 1 else "action=novellist&sort=lastupdate&page=1&t=0")
    print(status)
    print(text[:400])
