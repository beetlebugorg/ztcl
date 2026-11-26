# The sqlite_options array of testfixture, for shim.tcl and wone.tcl.
# SPDX-License-Identifier: BSD-2-Clause
# sqlite_options: 1 for a feature, 0 for the extensions that this build does not have.
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
