# The TechEmpower plaintext and JSON tests as a plain ASGI app:
#   uvicorn --app-dir bench/stdlib/http app:app --port PORT
# SPDX-License-Identifier: BSD-2-Clause
import json

async def app(scope, receive, send):
    path = scope.get("path")
    if path == "/plaintext":
        body, ctype = b"Hello, World!", b"text/plain"
    elif path == "/json":
        body, ctype = json.dumps({"message": "Hello, World!"}).encode(), b"application/json"
    else:
        await send({"type": "http.response.start", "status": 404, "headers": []})
        await send({"type": "http.response.body", "body": b""})
        return
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", ctype), (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})
