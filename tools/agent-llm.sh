#!/bin/sh
# Runs tests/llm/agent.tcl against a real local model, for example
# llama-server with its OpenAI-compatible API:
#
#   ZTCL_TEST_LLM=http://127.0.0.1:8090/v1 [ZTCL_TEST_MODEL=name] tools/agent-llm.sh
#
# With no ZTCL_TEST_LLM it prints "skip" and exits with 0. The endpoint
# must be a loopback address. CI does not run it.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "$ZTCL_TEST_LLM" ]; then echo "skip: no ZTCL_TEST_LLM"; exit 0; fi
case $ZTCL_TEST_LLM in http://127.0.0.1:*|http://localhost:*) ;; *) echo "ZTCL_TEST_LLM must be a loopback URL" >&2; exit 2 ;; esac
root=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-llm.XXXXXX") || exit 1
cp "$here/../tests/llm/agent.tcl" "$root/"
cd "$root" && "$here/../zig-out/bin/ztcl" --allow thread,event,socket,channels,meter --root "$root" --tclsh agent.tcl "$ZTCL_TEST_LLM" "${ZTCL_TEST_MODEL:-local}"
rc=$?
rm -rf -- "$root"
exit $rc
