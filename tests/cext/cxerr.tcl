# The checks of the error slots: tests/cext/cxerr.c.
puts [catch {load $dir/cxerr.so} msg]:$msg
proc show {script} {
    set c [catch $script m o]
    puts "$c [list $m] [list [dict get $o -errorcode]]"
    # tclsh adds the frame of `catch $script`; ztcl does not.
    set info [string map [list "\n    invoked from within\n\"catch \$script m o\"" ""] $::errorInfo]
    puts "  [string map [list \n |] $info]"
}
show {cxerr code boom {CX ONE two}}
show {cxerr codes}
show {cxerr info boom "\n    (extra)"}
show {cxerr eval {error inner {} {IN CODE}}}
show {cxerr eval {cxerr code deep {D E}}}
show {cxerr reset {error old {} {OLD}}}
proc p {} {cxerr code inproc X}
show {p}
puts [cxerr opts {error x {} {A B}}]
puts [cxerr opts {set y 1}]
puts [cxerr opts {cxerr code c {C D}}]
puts [catch {cxerr setopts {-code error -errorcode {S O} -errorinfo {custom info}} msg} m]:$m
puts [catch {cxerr setopts {-code break -level 0} m}]
proc q {} {cxerr setopts {-code error -level 1 -errorcode Q} qmsg; puts notreached}
show {q}
proc r {} {cxerr setopts {-code ok -level 1} rval; puts notreached}
puts [r]
show {cxerr setopts {-code bad} m}
show {cxerr setopts {-level -1} m}
show {cxerr posix}
show {cxerr parseexpr {1 +}}
show {cxerr parseexpr {0b12}}
show {cxerr parseexpr {"abc}}
show {cxerr parseexpr {f(,)}}
show {cxerr parseexpr {1 , 2}}
show {cxerr logcmd}
puts [cxerr line 7]
cxerr allow
proc bgerror {m} {puts "bg $m $::errorCode"}
puts [cxerr bg later]
update
