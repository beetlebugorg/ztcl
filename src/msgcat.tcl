# The commands of msgcat that are Tcl: mcpreferences, mcload, mcmax,
# and the export list. src/clock.zig has mc, mcset, mcmset, mcexists,
# and mclocale, and it evaluates this file after them. The commands
# follow the msgcat manual page of Tcl 8.6.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::msgcat {
    namespace export mc mcexists mcload mclocale mcmax mcmset \
        mcpreferences mcset mcunknown
}

# Gives the locale and its parents, from the most specific to the root
# (the empty string). For example, de_ch gives {de_ch de {}}.
proc ::msgcat::mcpreferences {} {
    set l [mclocale]
    set out {}
    while {$l ne ""} {
        lappend out $l
        set i [string last _ $l]
        if {$i < 0} break
        set l [string range $l 0 [expr {$i - 1}]]
    }
    lappend out {}
    return $out
}

# Reads the message file of each preferred locale in dir: de.msg,
# de_ch.msg, and ROOT.msg for the root. The file runs in the namespace
# of the caller. Gives the count of the files that it read.
proc ::msgcat::mcload {dir} {
    set n 0
    foreach p [lreverse [mcpreferences]] {
        if {$p eq ""} {set p ROOT}
        set f [file join $dir $p.msg]
        if {[file exists $f]} {
            uplevel 1 [list ::source -encoding utf-8 $f]
            incr n
        }
    }
    return $n
}

# Gives the length of the longest translation of the arguments.
proc ::msgcat::mcmax {args} {
    set max 0
    foreach s $args {
        set n [string length [uplevel 1 [list ::msgcat::mc $s]]]
        if {$n > $max} {set max $n}
    }
    return $max
}
