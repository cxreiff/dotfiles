#!/usr/bin/env python3
"""banner_server.py PORT — cxagents smoke fixture: on accept, sends an SSH-style
identification line immediately, then echoes every byte. Stdlib only."""
import socketserver
import sys

BANNER = b"SSH-2.0-cxsmoke\r\n"


class Banner(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(BANNER)
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server(("0.0.0.0", int(sys.argv[1])), Banner).serve_forever()
