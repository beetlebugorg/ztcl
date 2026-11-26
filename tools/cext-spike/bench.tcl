# A CPU benchmark of the binding with an in-memory database, for the
# native spike (tclsh) and the wasm spike (host.mjs). Prints the time of
# each part in ms.
# SPDX-License-Identifier: BSD-2-Clause
proc ms {script} {
  set t0 [clock milliseconds]
  uplevel 1 $script
  return [expr {[clock milliseconds] - $t0}]
}
sqlite3 db :memory:
db eval {create table t(a integer, b text, c real)}
set n [expr {[info exists ::n] ? $::n : 100000}]
puts "insert [ms {
  db transaction { for {set i 0} {$i < $n} {incr i} { db eval {insert into t values($i, 'row ' || $i, $i * 0.5)} } }
}]"
puts "select-list [ms { set l [db eval {select a, b, c from t}] }]"
puts "select-script [ms { set s 0; db eval {select a, c from t} { set s [expr {$s + $a}] } }]"
puts "sql-only [ms { db eval {select count(*), sum(a), avg(c) from t where b like '%9%'} }]"
db close
