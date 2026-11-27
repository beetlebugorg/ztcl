#!/bin/sh
# Builds the PDF examples, the typesetting examples, and the sample
# chapter of the book, and checks the structure of each PDF file with
# tools/pdf-check.py (and qpdf when it is on the PATH).
#
#   tests/typeset.sh [path/to/ztcl]
set -eu
ztcl=${1:-zig-out/bin/ztcl}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for e in invoice report letter manual labels; do
    "$ztcl" --allow channels,file --tclsh examples/pdf/$e.tcl "$out/$e.pdf" >/dev/null
done
"$ztcl" --allow channels,file --tclsh examples/typeset/compare.tcl "$out/compare.pdf" >/dev/null
"$ztcl" --allow channels,file,exec --exec-allow sh --tclsh book/build.tcl "$ztcl" "$out/book.pdf"
python3 -I tools/pdf-check.py "$out"/*.pdf
# The terminal example gives lines of 48 columns or fewer.
"$ztcl" examples/typeset/terminal.tcl | awk 'length > 48 { print "a line of " length " columns"; exit 1 }'
echo "typeset: ok"
