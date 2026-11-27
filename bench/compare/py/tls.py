# Opens COUNT TLS 1.3 connections. Each one does a full handshake, reads
# 1 MiB to the end, and closes.
import socket, ssl, sys
port, cafile, count = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
ctx = ssl.create_default_context(cafile=cafile)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
total = 0
for _ in range(count):
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as s:
            while True:
                b = s.recv(65536)
                if not b:
                    break
                total += len(b)
print(total)
