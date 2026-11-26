# Stand-ins for the commands of testfixture, the test program of SQLite.
# tester.tcl calls them, and tclsh has none of them. Each one gives a
# neutral value, so a test that needs the real command fails.
# SPDX-License-Identifier: BSD-2-Clause
foreach c {sqlite3_test_control_pending_byte sqlite3_soft_heap_limit64 sqlite3_hard_heap_limit64
           sqlite3_memdebug_settitle sqlite3_memdebug_log sqlite3_reset_auto_extension
           sqlite3_clear_tsd_memdebug sqlite3_db_config_lookaside sqlite3_config_lookaside
           sqlite3_initialize sqlite3_shutdown autoinstall_test_functions
           install_malloc_faultsim sqlite3_extended_result_codes sqlite3_test_control
           sqlite3_memdebug_backtrace sqlite3_config_pagecache sqlite3_config} {
  if {[info commands $c] eq ""} { proc $c args { return 0 } }
}
proc sqlite3_memory_used args { return 0 }
proc sqlite3_memory_highwater args { return 0 }
proc sqlite3_status args { return {0 0 0} }
proc sqlite3_memdebug_malloc_count args { return 0 }
proc sqlite3_memdebug_pending args { return -1 }
proc sqlite3_memdebug_fail args { return 0 }
proc working_64bit_int {} { return 1 }
proc sqlite_options_dummy {} {}
array set ::sqlite_options {}
set ::sqlite_open_file_count 0
# Any other command of testfixture returns "", and the count goes in ::shimmed.
rename unknown _orig_unknown
proc unknown {cmd args} {
  if {[catch {uplevel 1 [list _orig_unknown $cmd {*}$args]} r o]} {
    if {[string match "invalid command name*" $r]} { dict incr ::shimmed $cmd; return "" }
    return -options $o $r
  }
  return $r
}
set ::shimmed {}
# sqlite_options: 1 for a feature, 0 for the extensions that this build has not.
foreach o {fts3 fts4 fts5 rtree geopoly session preupdate icu dbstat_vtab stat4 rbu
           default_autovacuum mem3 mem5 memdebug malloc_fail threadsafe2 columnmetadata
           unlock_notify atomic_write batch_atomic_write zipvfs bytecode tabledef
           carray offset_sql_func normalize stmtvtab dbpage diskio crashtest
           lock_proxy_pragmas prefer_proxy_locking secure_delete} {
  set ::sqlite_options($o) 0
}
proc _opt_read {n e op} { if {![info exists ::sqlite_options($e)]} { set ::sqlite_options($e) 1 } }
trace add variable ::sqlite_options read _opt_read
set ::sqlite_options(threadsafe) 1
