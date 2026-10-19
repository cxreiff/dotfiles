#!/usr/bin/env python3
"""ws_echo_server.py PORT — cxagents smoke fixture: threaded HTTP/1.1 server.
GET / returns a page containing cxsmoke-ws. A request with Upgrade: websocket
gets the RFC 6455 handshake, then echoes text/binary frames (client frames are
unmasked; replies are unmasked), answers ping with pong and close with close.
Stdlib only."""
import base64
import hashlib
import http.server
import socketserver
import struct
import sys

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PAGE = b"<!doctype html><title>cxsmoke-ws</title><p>cxsmoke-ws</p>\n"


def recv_exact(rfile, n):
    buf = b""
    while len(buf) < n:
        chunk = rfile.read(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_frame(rfile):
    b1, b2 = recv_exact(rfile, 2)
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(rfile, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(rfile, 8))[0]
    mask = recv_exact(rfile, 4) if masked else b""
    payload = recv_exact(rfile, length) if length else b""
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def send_frame(wfile, opcode, payload=b""):
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    wfile.write(head + payload)
    wfile.flush()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "cxsmoke"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.websocket()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(PAGE)
        self.close_connection = True

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        while True:
            try:
                opcode, payload = read_frame(self.rfile)
            except (EOFError, OSError):
                return
            if opcode == 0x8:
                send_frame(self.wfile, 0x8, payload[:2])
                return
            if opcode == 0x9:
                send_frame(self.wfile, 0xA, payload)
            elif opcode in (0x1, 0x2):
                send_frame(self.wfile, opcode, payload)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    Server(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
