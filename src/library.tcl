# The library commands of Tcl for an interpreter with the capability
# package: auto_path, the handler of `package unknown` that reads the
# pkgIndex.tcl files of auto_path, auto_load with tclIndex files,
# auto_execok, auto_qualify, and history. The commands follow the manual
# pages library.n and package.n of Tcl 8.6. src/interp.zig evaluates
# this file when it turns on package. A search needs the capability file
# when it runs; with no file, it finds nothing.
# SPDX-License-Identifier: BSD-2-Clause

if {![info exists ::auto_path]} {set ::auto_path {}}
if {![info exists ::tcl_library]} {set ::tcl_library {}}
if {![info exists ::tcl_pkgPath]} {set ::tcl_pkgPath {}}
namespace eval ::tcl {
    variable pkgScanned {}
}

# Sources the pkgIndex.tcl file of each folder of auto_path and of each
# folder in it that the earlier calls did not read. A pkgIndex.tcl file
# runs with the variable dir set to its folder.
proc ::tclPkgUnknown {name args} {
    if {[info commands ::file] eq ""} return
    set dirs {}
    foreach d $::auto_path {
        lappend dirs $d
        catch {lappend dirs {*}[glob -nocomplain -types d -directory $d *]}
    }
    foreach d $dirs {
        set f [file join $d pkgIndex.tcl]
        if {$f in $::tcl::pkgScanned || ![file readable $f]} continue
        lappend ::tcl::pkgScanned $f
        ::tcl::SourceIndex $d $f
    }
}

# Runs one pkgIndex.tcl in a procedure, so its variables stay local.
proc ::tcl::SourceIndex {dir file} {
    if {[catch {source $file} msg]} {
        catch {::tclLog "error reading package index file $file: $msg"}
    }
}

proc ::tclLog {msg} {
    catch {puts stderr $msg}
}

package unknown ::tclPkgUnknown

# Loads the definition of a command from auto_index, which the
# tclIndex files of auto_path and tclPkgSetup fill. Gives 1 when the
# command exists after it, else 0.
proc ::auto_load {cmd {namespace {}}} {
    variable ::auto_index
    for {set round 0} {$round < 2} {incr round} {
        foreach name [::auto_qualify $cmd $namespace] {
            set bare [string trimleft $name :]
            foreach key [list $name ::$bare $bare] {
                if {[info exists auto_index($key)]} {
                    uplevel #0 $auto_index($key)
                    if {[info commands ::$bare] ne ""} {return 1}
                }
            }
        }
        if {$round == 0 && ![::auto_load_index]} {return 0}
    }
    return 0
}

# Reads the tclIndex file of each folder of auto_path into auto_index,
# once for each value of auto_path. Gives 1 when it read a new file.
proc ::auto_load_index {} {
    variable ::auto_index
    if {[info commands ::file] eq ""} {return 0}
    if {[info exists ::tcl::autoIndexPath] && $::tcl::autoIndexPath eq $::auto_path} {return 0}
    set ::tcl::autoIndexPath $::auto_path
    set read 0
    foreach d $::auto_path {
        set f [file join $d tclIndex]
        if {![file readable $f]} continue
        set dir $d
        if {[catch {source $f}] == 0} {set read 1}
    }
    return $read
}

# The lazy form of pkgIndex.tcl from pkg_mkIndex -lazy: each command of
# a file goes in auto_index, and the package is provided.
proc ::tclPkgSetup {dir pkg version files} {
    variable ::auto_index
    foreach info $files {
        lassign $info file type procs
        set path [file join $dir $file]
        set script [expr {$type eq "load" ? [list load $path $pkg] : [list source $path]}]
        foreach p $procs {set auto_index($p) $script}
    }
    package provide $pkg $version
}

# A command with no definition: auto_load can define it, and else the
# error is the error of Tcl.
rename ::unknown ::tcl::UnknownBuiltin
proc ::unknown {cmd args} {
    if {[::auto_load $cmd [uplevel 1 {namespace current}]]} {
        return [uplevel 1 [list [regsub -all {:::+} $cmd ::] {*}$args]]
    }
    return -code error -errorcode [list TCL LOOKUP COMMAND $cmd] "invalid command name \"$cmd\""
}

# The commands of the library packages that load on their first call,
# as the tclIndex of the Tcl library gives them.
proc ::tcl::LibraryIndex {} {
    foreach c {interpCreate interpInit interpConfigure interpDelete
            interpAddToAccessPath interpFindInAccessPath setLogCmd} {
        set ::auto_index(::safe::$c) {package forget safe; package require safe}
    }
    set ::auto_index(parray) {
        # Prints the elements of an array, one on each line, with the
        # signs = in one column.
        proc ::parray {a {pattern *}} {
            upvar 1 $a array
            if {![array exists array]} {
                return -code error "\"$a\" isn't an array"
            }
            set names [lsort [array names array $pattern]]
            set width 0
            foreach name $names {
                set n [string length "${a}($name)"]
                if {$n > $width} {set width $n}
            }
            foreach name $names {
                puts stdout [format "%-*s = %s" $width "${a}($name)" $array($name)]
            }
        }
    }
}
::tcl::LibraryIndex

proc ::auto_reset {} {
    variable ::auto_index
    array unset auto_index
    ::tcl::LibraryIndex
    set ::tcl::pkgScanned {}
    unset -nocomplain ::tcl::autoIndexPath
}

# The names to look up for a command, as Tcl searches them. A run of
# colons counts as one separator. A name with a leading :: is global,
# and else the name in the namespace comes first.
proc ::auto_qualify {cmd namespace} {
    regsub -all {:::+} $cmd :: cmd
    if {[string match ::* $cmd]} {
        set rest [string range $cmd 2 end]
        if {[string first :: $rest] >= 0} {return [list $cmd]}
        return [list $rest]
    }
    if {[string first :: $cmd] >= 0} {
        if {$namespace eq "::" || $namespace eq ""} {return [list ::$cmd]}
        return [list ${namespace}::$cmd ::$cmd]
    }
    if {$namespace eq "::" || $namespace eq ""} {return [list $cmd]}
    return [list ${namespace}::$cmd $cmd]
}

proc ::auto_import {pattern} {}

# The full path of a program in the folders of PATH, or an empty string.
proc ::auto_execok {name} {
    if {[info commands ::file] eq ""} return
    if {[file pathtype $name] ne "relative" || [string first / $name] >= 0} {
        if {[file executable $name] && ![file isdirectory $name]} {return [list $name]}
        return
    }
    if {![info exists ::env(PATH)]} return
    set sep [expr {$::tcl_platform(platform) eq "windows" ? ";" : ":"}]
    foreach d [split $::env(PATH) $sep] {
        if {$d eq ""} {set d .}
        set f [file join $d $name]
        if {[file executable $f] && ![file isdirectory $f]} {return [list $f]}
    }
    return
}

# ---- history ----

namespace eval ::tcl::history {
    variable list {}
    variable keep 20
    variable next 1
}

# The number of an event: a number, a negative offset from the next
# event, or the newest event that starts with a text.
proc ::tcl::history::Find {{event -1}} {
    variable list
    variable next
    if {[string is integer -strict $event]} {
        set n [expr {$event <= 0 ? $next + $event : $event}]
    } else {
        set n ""
        for {set i [expr {[llength $list] - 1}]} {$i >= 0} {incr i -1} {
            lassign [lindex $list $i] id cmd
            if {[string match $event* $cmd]} {set n $id; break}
        }
        if {$n eq ""} {return -code error "no event matches \"$event\""}
    }
    foreach e $list {
        if {[lindex $e 0] == $n} {return $n}
    }
    return -code error "event \"$event\" is too far in the past"
}

proc ::tcl::history::Get {n} {
    variable list
    foreach e $list {
        if {[lindex $e 0] == $n} {return [lindex $e 1]}
    }
}

proc ::history {{option info} args} {
    upvar #0 ::tcl::history::list list ::tcl::history::keep keep ::tcl::history::next next
    switch -- $option {
        add {
            set cmd [string trim [lindex $args 0]]
            if {$cmd eq ""} return
            lappend list [list $next $cmd]
            incr next
            if {[llength $list] > $keep} {set list [lrange $list end-[expr {$keep - 1}] end]}
            if {[lindex $args 1] eq "exec"} {return [uplevel #0 $cmd]}
            return
        }
        change {
            set n [::tcl::history::Find [expr {[llength $args] > 1 ? [lindex $args 1] : 0}]]
            set i 0
            foreach e $list {
                if {[lindex $e 0] == $n} {lset list $i 1 [lindex $args 0]}
                incr i
            }
            return
        }
        clear {set list {}; set next 1; return}
        event {return [::tcl::history::Get [::tcl::history::Find {*}$args]]}
        info {
            set count [expr {[llength $args] ? [lindex $args 0] : [llength $list]}]
            set out {}
            foreach e [lrange $list end-[expr {$count - 1}] end] {
                lappend out [format %6d [lindex $e 0]]\t[string map [list \n "\n\t"] [lindex $e 1]]
            }
            return [join $out \n]
        }
        keep {
            if {[llength $args] == 0} {return $keep}
            set keep [lindex $args 0]
            return
        }
        nextid {return $next}
        redo {return [uplevel #0 [::tcl::history::Get [::tcl::history::Find {*}$args]]]}
        default {
            return -code error "unknown or ambiguous subcommand \"$option\": must be add, change, clear, event, info, keep, nextid, or redo"
        }
    }
}
