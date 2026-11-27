#!/bin/sh
# Maps the changed files of a pull request to the jobs of ci.yml.
#
# Usage: tools/ci-changes.sh [--all | --none] < files
#
# The input has one path for each line. The output has one line
# NAME=true or NAME=false for each job gate, in the format of
# $GITHUB_OUTPUT. With --all, each gate is true (pushes to main and
# the full runs). With --none, each gate is false (pull requests: the
# QA agents run the jobs, and they use this script to pick them).
#
# Each path goes in the first area whose pattern it matches. A path
# that matches no area is in the area core, and core runs each job.
# A change of a workflow, build.zig, or build.zig.zon also runs each
# job. docs/dev/ci.md has the table of the areas and the jobs.
set -eu

if [ "${1:-}" = --all ] || [ "${1:-}" = --none ]; then
  v=true; if [ "$1" = --none ]; then v=false; fi
  for g in code docs test native suite jit cext cext_wasm wasm wasm_compile wasi wasm_engine; do
    echo "$g=$v"
  done
  exit 0
fi

# The areas, as extended regular expressions. The order is important:
# the first match wins.
re_all='^(\.github/|build\.zig$|build\.zig\.zon$|tools/ci-changes\.sh$)'
re_docs='^(docs/|[^/]+\.md$|licenses/|specs/|tools/build-docs\.py$|tools/docs-requirements\.txt$|tools/(doc-coverage|doc-examples|ref-coverage|reference|suite-md|suite-table)\.py$|tests/site\.sh$|tools/site-)'
re_jit='^(src/jit/|src/(jit|disasm)\.zig$|tests/jit/|tools/jit-)'
re_vm='^(src/vm/|src/(kvm|microvm|vmagent|vmimage|vmstore|vmrelay|vz|whp|isovm|unikernel)\.zig$|src/vmimage_fixtures/|src/uk/|tools/vm-guest/|tools/vm-image-verify/)'
re_wasm_engine='^(src/wasmrt/|src/wasm_(spec|fuzz)\.zig$|tests/wasm/)'
re_cext='^(src/cext/|src/(cext_stubs|libztcl|libtcl|tclstub|wasm_cext)\.zig$|tests/(cext|libztcl)/|tools/(cext|cext-spike|libztcl)/)'
re_web='^(web/|npm/|wit/|enclave/|examples/web/|src/web/|src/wasi/|src/wasm_aot/|src/(wasm|wasmweb|wasmdom|wasm_shell|wasmfiles|wasm_link|wasm_out|wasmbundle|webasync|webthread|point_wasm|point_rt|point_fuzz|sys_wasi|sys_wasi3|fsroot_wasi|fsroot_wasi3|enclave_core)\.zig$|tests/(web|point)/|tools/(wasm|wasi|point|web|witgen|webidl))'
re_stdlib='^(src/(tls|crypto|h2|json|text)/|tools/(tls-|fetch-wycheproof|fetch-x509|rfc8448|hpack|json-))'
# Code of one host OS, and the unit test files: the native build and
# its unit tests only.
re_native='^(src/[^/]*_(windows|mac|macos)(_tests)?\.zig$|src/(win[a-z]*|macho|mac|tests|[a-z0-9_]*_tests)\.zig$|tests/strip\.sh$|tests/targets\.sh$|packaging/|tools/macho-sign/|src/shell/reference\.txt$|tools/size-)'

all=false docs=false core=false jit=false vm=false wasm_engine=false
cext=false web=false stdlib=false native=false
while IFS= read -r f; do
  case $f in ''|*/__pycache__/*) continue ;; esac
  if printf '%s\n' "$f" | grep -qE "$re_all"; then all=true
  elif printf '%s\n' "$f" | grep -qE "$re_docs"; then docs=true
  elif printf '%s\n' "$f" | grep -qE "$re_jit"; then jit=true
  elif printf '%s\n' "$f" | grep -qE "$re_vm"; then vm=true
  elif printf '%s\n' "$f" | grep -qE "$re_wasm_engine"; then wasm_engine=true
  elif printf '%s\n' "$f" | grep -qE "$re_cext"; then cext=true
  elif printf '%s\n' "$f" | grep -qE "$re_web"; then web=true
  elif printf '%s\n' "$f" | grep -qE "$re_stdlib"; then stdlib=true
  elif printf '%s\n' "$f" | grep -qE "$re_native"; then native=true
  else core=true
  fi
done

if $all; then exec "$0" --all; fi

echo "areas: docs=$docs core=$core jit=$jit vm=$vm wasm_engine=$wasm_engine cext=$cext web=$web stdlib=$stdlib native=$native" >&2

any() { for a in "$@"; do if [ "$a" = true ]; then echo true; return; fi; done; echo false; }

code=$(any $core $jit $vm $wasm_engine $cext $web $stdlib $native)
echo "code=$code"
echo "docs=$docs"
# The quick Linux tests and the native build of each target: each
# change of code.
echo "test=$code"
# The unit tests on arm64 Linux.
echo "native=$(any $core $jit $vm $wasm_engine $cext $stdlib $native)"
# The Tcl suite, and the differential test and the fuzzer of the JIT.
echo "suite=$(any $core $jit)"
echo "jit=$(any $core $jit)"
echo "cext=$(any $core $jit $cext)"
echo "cext_wasm=$(any $core $cext $web)"
# The builds for the browser: each change of code, so that a break of
# the wasm32 build shows.
echo "wasm=$code"
echo "wasm_compile=$(any $core $jit $web)"
echo "wasi=$(any $core $web $stdlib $cext)"
echo "wasm_engine=$(any $core $wasm_engine $cext)"
