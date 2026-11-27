# The platform package 1.0.19: the names of the system and the CPU, as
# the manual page platform.n of Tcl 8.6 describes them. src/tcllib.zig
# has this file.
#
# An identifier is OS-CPU. The OS part comes from tcl_platform(os) with
# the names of Tcl (macosx, linux, win32), and the CPU part from
# tcl_platform(machine), with ix86 for the 32-bit Intel CPUs.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::platform {
    namespace export generic identify patterns
}

proc ::platform::generic {} {
    global tcl_platform
    set os [expr {[info exists tcl_platform(os)] ? $tcl_platform(os) : "unknown"}]
    set cpu [expr {[info exists tcl_platform(machine)] ? $tcl_platform(machine) : "unknown"}]
    set plat [expr {[info exists tcl_platform(platform)] ? $tcl_platform(platform) : "unix"}]
    if {$plat eq "windows"} {
        set os win32
    } else {
        set os [string tolower $os]
        switch -glob -- $os {
            darwin {set os macosx}
            sunos* {set os solaris}
            aix* {set os aix}
            hp-ux* {set os hpux}
            freebsd* {set os freebsd}
            netbsd* {set os netbsd}
            openbsd* {set os openbsd}
        }
    }
    set cpu [string tolower $cpu]
    switch -glob -- $cpu {
        i*86 - x86 - intel {set cpu ix86}
        amd64 - x86_64 {set cpu x86_64}
        aarch64 {set cpu arm64}
        "" {set cpu unknown}
    }
    if {$os eq "macosx" && $cpu eq "arm64"} {set cpu arm}
    regsub -all -- - $cpu _ cpu
    return $os-$cpu
}

# The identifier with the details of the system. ztcl has no more
# details than generic gives.
proc ::platform::identify {} {
    return [generic]
}

# The identifiers that a package built for an identifier can run on:
# the identifier, its generic form, and tcl for pure Tcl packages.
proc ::platform::patterns {id} {
    set out [list $id]
    set generic [generic]
    if {$generic ni $out && [string match [lindex [split $generic -] 0]* $id]} {
        lappend out $generic
    }
    lappend out tcl
    return $out
}

package provide platform 1.0.19
