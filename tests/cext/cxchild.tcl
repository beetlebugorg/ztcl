# The checks of the interp tree of the area interps and commands:
# tests/cext/cxinterp.c through cxchild.c.
load $dir/cxchild.so
proc try {script} {
    set rc [catch {uplevel 1 $script} msg]
    puts "  $rc: $msg"
}

puts children
try {cxinterp child c1 0}
try {cxinterp child s1 1}
try {cxinterp getchild c1}
try {cxinterp getchild s1}
try {cxinterp getchild nosuch}
interp create c2
interp create {c2 g}
try {cxinterp getchild {c2 g}}
try {cxinterp master {c2 g}}
try {cxinterp master c2}
try {cxinterp path {} {c2 g}}
try {cxinterp path c2 {c2 g}}
try {cxinterp path {c2 g} {}}
try {cxinterp eval c1 {set x 5; incr x}}
try {cxinterp eval {c2 g} {info exists x}}
try {cxinterp child c1 0}
try {cxinterp makesafe c2}
try {cxinterp getchild c2}
try {interp eval c2 {info commands exec}}
try {cxinterp active c1}
try {cxinterp active {}}

puts aliases
proc ::hello {args} { return "hello $args" }
try {cxinterp alias c1 hi {} hello x y}
try {interp eval c1 {hi z}}
try {cxinterp alias c1 hi2 {} hello -obj p {q r}}
try {interp eval c1 {hi2 s}}
try {cxinterp alias {} up {c2 g} set}
try {interp eval {c2 g} {set v 7}}
try {up v}
try {cxinterp alias {c2 g} side c1 set w}
try {interp eval {c2 g} {side 9}}
try {interp eval c1 {set w}}
try {cxinterp getalias c1 hi}
try {cxinterp getalias c1 hi2}
try {cxinterp getalias {} up}
try {cxinterp getalias {c2 g} side}
try {cxinterp getalias c1 nosuch}
puts [lsort [interp aliases c1]]

puts hidden
try {cxinterp hide c1 set hset}
try {interp invokehidden c1 hset a 1}
puts [interp hidden c1]
try {cxinterp hide c1 nosuch h2}
try {cxinterp expose c1 hset set}
try {interp eval c1 {set a}}
try {cxinterp expose c1 nosuch x}
interp recursionlimit c1 40
try {cxinterp recursion c1 50}
try {cxinterp recursion c1 60}
try {interp recursionlimit c1}

puts deleted
cxinterp whendeleted c1 a
cxinterp whendeleted c1 b
cxinterp whendeleted s1 a
cxinterp dontcall s1 a
interp delete c1
puts [cxinterp log]
interp delete s1
puts [cxinterp log]
cxinterp whendeleted {c2 g} a
interp delete c2
puts [cxinterp log]

puts limits
interp create lim
try {cxinterp limits lim}
puts [cxinterp log]
interp delete lim
puts [cxinterp log]
