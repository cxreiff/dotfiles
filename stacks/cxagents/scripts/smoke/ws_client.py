#!/usr/bin/env python3
"""ws_client.py URL [--idle SECONDS] — cxagents smoke client (runs on the Mac).
Connects to wss://host:port/ with certificate verification on (system trust,
SNI = host), upgrades, sends a masked text frame "hello" and expects the echo.
With --idle N, sleeps N seconds and then sends "again" and expects the echo.
Prints "ok" and exits 0; otherwise prints the failure and exits 1. Stdlib only."""
import base64
import hashlib
import os
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urlsplit

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def masked_frame(opcode, payload):
    mask = os.urandom(4)
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def read_exact(rf, n):
    buf = b""
    while len(buf) < n:
        chunk = rf.read(n - len(buf))
        if not chunk:
            raise RuntimeError("connection closed by peer")
        buf += chunk
    return buf


def read_frame(rf):
    b1, b2 = read_exact(rf, 2)
    opcode = b1 & 0x0F
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(rf, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(rf, 8))[0]
    return opcode, read_exact(rf, length)


def expect_echo(tls, rf, text):
    tls.sendall(masked_frame(0x1, text))
    opcode, payload = read_frame(rf)
    if opcode != 0x1 or payload != text:
        raise RuntimeError("expected echo %r, got opcode %d payload %r" % (text, opcode, payload[:80]))


def main(argv):
    if not argv or argv[0].startswith("-"):
        raise SystemExit("usage: ws_client.py URL [--idle SECONDS]")
    url = argv[0]
    idle = 0
    if "--idle" in argv:
        i = argv.index("--idle")
        if i + 1 >= len(argv):
            raise RuntimeError("--idle needs a number of SECONDS")
        idle = int(argv[i + 1])  # non-numeric -> ValueError -> "fail: ..." exit 1
        if idle < 0:
            raise RuntimeError("--idle must not be negative")
    parts = urlsplit(url)
    if parts.scheme != "wss" or not parts.hostname:
        raise SystemExit("ws_client: URL must be wss://host[:port]/")
    host = parts.hostname
    port = parts.port or 443
    path = parts.path or "/"
    key = base64.b64encode(os.urandom(16)).decode()
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    ctx = ssl.create_default_context()
    raw = socket.create_connection((host, port), timeout=15)
    tls = ctx.wrap_socket(raw, server_hostname=host)
    try:
        tls.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
                     "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                     "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key)).encode())
        rf = tls.makefile("rb")
        status = rf.readline().decode("latin-1").strip()
        headers = {}
        while True:
            line = rf.readline().decode("latin-1").strip()
            if not line:
                break
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        if not status.startswith("HTTP/1.1 101"):
            raise RuntimeError("expected 101, got: %s" % status)
        if headers.get("sec-websocket-accept") != expected:
            raise RuntimeError("bad Sec-WebSocket-Accept")
        expect_echo(tls, rf, b"hello")
        if idle:
            time.sleep(idle)
            expect_echo(tls, rf, b"again")
        print("ok")
        return 0
    finally:
        tls.close()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, RuntimeError, ssl.SSLError, ValueError) as e:
        print("fail: %s" % e)
        sys.exit(1)
