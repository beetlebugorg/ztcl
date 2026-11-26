# The checks of the area scripts and results: tests/cext/cxscript.c.
namespace eval cxscript {}
load $dir/cxscript.so
set g 5
foreach {name arg} {
    exprlong {6 * 7} exprlong {1 +} exprlong {"x"} exprdouble {1 / 4.0}
    exprboolean {$g > 2} exprboolean {"maybe"} exprobj {[llength {a b}] + $g}
    exprstring {$g * 2} evalobjv {string repeat {a b} 2} evalobjv {set {a b}}
    globalevalobj {set ::g} evalobj {incr g} vareval abc append mid
    subst {7 {$g [set g] \t}} subst {4 {$g [set g] \t}} subst {2 {$g \t}}
    subst {7 {$nosuch}}
    saveresult - interpstate - recordandeval {set g} freeresult - canceled -
} {
    puts "$name [list $arg]: [catch {cxscript::run $name $arg} msg] [list $msg]"
}
foreach arg [list {set a b} "set a \{" {a [b "} "a \\\{" "# \{\n"] {
    puts "complete [string length $arg]: [cxscript::run complete $arg]"
}
