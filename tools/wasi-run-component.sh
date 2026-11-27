#!/bin/sh
# Runs the command component of WASI 0.3.2 with the arguments of
# zig-out/bin/ztcl, so `tools/suite.sh -r tools/wasi-run-component.sh`
# runs the suite under the component. See tools/wasi-run.sh.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$here/wasi-run.sh" --component "$@"
