# Parses a JSON file of records and writes it again with no spaces.
import json, os, sys
with open(os.path.join(sys.argv[1], "data.json")) as f:
    data = json.load(f)
sys.stdout.write(json.dumps(data, separators=(",", ":")))
sys.stdout.write("\n")
