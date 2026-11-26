# Runs one SQLite test file in ztcl-host.wasm with the binding of
# libztclstubs.a (bridge-test.mjs). The `load` command makes the package.
# SPDX-License-Identifier: BSD-2-Clause
load sqlite.wasm Sqlite3
source [file join $::shimdir wone.tcl]
