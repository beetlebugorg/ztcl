# Encodes 16 MB of bytes to base64 and decodes them again.
import base64, os, sys
with open(os.path.join(sys.argv[1], "bytes.bin"), "rb") as f:
    data = f.read()
enc = base64.b64encode(data)
dec = base64.b64decode(enc)
e = enc.decode("ascii")
print(len(e), e[:16], e[-16:], "ok" if dec == data else "bad")
