# Runs one SQLite test file on tclsh with the recording extension.
#   SPIKE=... tclsh one.tcl FILE.test
# SPDX-License-Identifier: BSD-2-Clause
set S $env(SPIKE)
source [file join [file dirname [file normalize [info script]]] shim.tcl]
load $S/rec/librecsqlite.so Sqlite3
set argv0 [lindex $argv 0]
set argv [lrange $argv 1 end]
set ::testdir $S/src/sqlite-src-3540100/test
source $argv0
