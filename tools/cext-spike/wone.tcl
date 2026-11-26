# Runs one SQLite test file in ztcl-host.wasm with sqlite.wasm (host.mjs).
# host.mjs sets ::spike and ::shimdir.
# SPDX-License-Identifier: BSD-2-Clause
source [file join $::shimdir shim.tcl]
set ::sqlite_options(threadsafe) 0
set ::testdir $::spike/src/sqlite-src-3540100/test
set argv0 [lindex $argv 0]
set argv [lrange $argv 1 end]
source $argv0
