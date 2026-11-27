# An HTTP/1.1 server with keep-alive on one thread, from http.server.
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
BODY = b'{"ok":true,"n":42}'
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # The handler writes the head and the body in two sends. With Nagle on,
    # each response waits for the delayed ACK of the client (40 ms).
    disable_nagle_algorithm = True
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *args):
        pass
srv = HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
print("ready", flush=True)
srv.serve_forever()
