"""Makes src/tls/testdata/rfc8448.txt from the text of RFC 8448.

    python3 -I tools/rfc8448-vectors.py rfc8448.txt > src/tls/testdata/rfc8448.txt

Fetch the RFC from https://www.rfc-editor.org/rfc/rfc8448.txt. The output
has one line for each step of a trace and one line for each value:

    S <section> <client|server> <the text of the step>
    V <name> <hex, or - for no bytes>

The page breaks of the RFC are left out. A value with no hex in the RFC,
such as the salt "0 (all zero octets)", is written as "0".

SPDX-License-Identifier: BSD-2-Clause
"""
import re
import sys

step_re = re.compile(r"^   \{(client|server)\}  (.*?):?\s*$")
value_re = re.compile(r"^      (\S.*?) \((\d+) octets\):\s*(.*)$")
hex_re = re.compile(r"^         ((?:[0-9a-f]{2} ?)+)$")
section_re = re.compile(r"^(\d+)\.  ")


def main():
    lines = open(sys.argv[1]).read().split("\n")
    section = None
    out = []
    cur = None
    step = None
    for line in lines:
        if line.startswith("\f") or line.startswith("RFC 8448") or line.startswith("Thomson"):
            continue
        m = section_re.match(line)
        if m:
            section = int(m.group(1))
            cur = None
            continue
        if section is None or not 3 <= section <= 7:
            continue
        m = step_re.match(line)
        if m:
            cur = None
            step = "S %d %s %s" % (section, m.group(1), m.group(2).rstrip(":").strip())
            out.append(step)
            continue
        m = value_re.match(line)
        if m:
            name, n, rest = m.group(1), int(m.group(2)), m.group(3).strip()
            if rest.startswith("(empty)"):
                rest = ""
            elif rest.startswith("0 (all zero"):
                rest = "0"
            cur = [name, n, rest.replace(" ", "")]
            out.append(cur)
            continue
        # A "salt:  0 (all zero octets)" line has no octet count.
        if line.startswith("      salt:") and "all zero" in line:
            out.append(["salt", 0, "0"])
            cur = None
            continue
        m = hex_re.match(line)
        if m and cur is not None:
            cur[2] += m.group(1).replace(" ", "")
            continue
        if line.strip() == "":
            continue
        cur = None
    for o in out:
        if isinstance(o, str):
            print(o)
            continue
        name, n, h = o
        if h != "0" and len(h) != 2 * n:
            raise SystemExit("%s: %d octets expected, %d found" % (name, n, len(h) // 2))
        print("V %s %s" % (name.replace(" ", "_"), h or "-"))


main()
