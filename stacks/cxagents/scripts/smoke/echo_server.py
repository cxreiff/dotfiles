#!/usr/bin/env python3
"""echo_server.py PORT [BIND] — cxagents smoke fixture: threaded TCP server that
echoes every byte back. Stdlib only. Default bind 0.0.0.0."""
import socketserver
import sys


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1])
    bind = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
    Server((bind, port), Echo).serve_forever()
