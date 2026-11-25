# The SQLite benchmark of tclsh: tclsh bench.tcl ROWS
# TCLSQLITE is the folder of the sqlite3 package. Prints
# "select SECONDS" and "insert SECONDS", the best of 3 runs.
# SPDX-License-Identifier: BSD-2-Clause
lappend auto_path $env(TCLSQLITE)
package require sqlite3
set rows [lindex $argv 0]
sqlite3 db :memory:
db eval {CREATE TABLE t(a INTEGER, b REAL, c TEXT)}
proc insert {rows} {
    db eval {DELETE FROM t}
    set t [clock microseconds]
    db transaction {
        for {set i 0} {$i < $rows} {incr i} {
            db eval {INSERT INTO t VALUES($i, $i * 0.5, 'row')}
        }
    }
    expr {([clock microseconds] - $t) / 1e6}
}
proc select {} {
    set t [clock microseconds]
    db eval {SELECT a, b, c FROM t} r {}
    expr {([clock microseconds] - $t) / 1e6}
}
set bi 1e9; set bs 1e9
for {set k 0} {$k < 3} {incr k} {
    set bi [expr {min($bi, [insert $rows])}]
    set bs [expr {min($bs, [select])}]
}
puts "insert $bi"
puts "select $bs"
