# The safe package 0.10: the Safe Base of Tcl, as the manual page
# safe.n of Tcl 8.6 describes it. src/tcllib.zig has this file, and
# src/library.tcl puts its commands in auto_index.
#
# safe::interpCreate makes a safe child and gives it aliases into this
# interpreter: source, load, glob, encoding, exit, clock, and the file
# subcommands. A child sees a directory of its access path only as a
# token, $p(:N:) for the place N in the list. An alias turns the
# tokens of a path back into the real directories and checks the path
# against the access path before it reads a file. The state of a child
# is the array ::safe::S<child>.
#
# A safe child of ztcl has no hidden commands, so the source alias
# reads the file here and evaluates the text in the child. The child
# has the small package command, which runs no ifneeded script.
# SPDX-License-Identifier: BSD-2-Clause

package require opt 0.4.9

namespace eval ::safe {
    namespace export interpCreate interpInit interpConfigure interpDelete \
        interpAddToAccessPath interpFindInAccessPath setLogCmd
    variable Log {}
    # The file subcommands that a child runs here, with ~ as a plain
    # name.
    variable FileSafe {dirname extension rootname tail}
    variable FileBad {atime attributes copy delete executable exists
        isdirectory isfile link lstat mkdir mtime nativename normalize
        owned readable readlink rename size stat tempfile type volumes
        writable}
}

::tcl::OptKeyRegister {
    {?slave? -name {} "name of the slave (optional)"}
    {-accessPath -list {} "access path for the slave"}
    {-noStatics -boolflag "prevent loading of statically linked pkgs"}
    {-statics -boolean true "loading of statically linked pkgs"}
    {-nestedLoadOk -boolflag "allow nested loading"}
    {-nested -boolean false "nested loading"}
    {-deleteHook -script {} "delete hook"}
} ::safe::interpCreate

::tcl::OptKeyRegister {
    {slave -name {} "name of the slave"}
    {-accessPath -list {} "access path for the slave"}
    {-noStatics -boolflag "prevent loading of statically linked pkgs"}
    {-statics -boolean true "loading of statically linked pkgs"}
    {-nestedLoadOk -boolflag "allow nested loading"}
    {-nested -boolean false "nested loading"}
    {-deleteHook -script {} "delete hook"}
} ::safe::interpIC

# Checks the options of a parse of interpCreate or interpIC, and gives
# the dict accessPath statics nested deleteHook, with only the options
# that the words had.
proc ::safe::Options {key} {
    upvar 1 accessPath accessPath noStatics noStatics statics statics \
        nestedLoadOk nestedLoadOk nested nested deleteHook deleteHook
    set given $::tcl::OptGiven($key)
    set out [dict create]
    if {"-accessPath" in $given} {dict set out accessPath $accessPath}
    if {"-noStatics" in $given} {
        if {"-statics" in $given && $statics} {
            return -code error "conflicting values given for -statics and -noStatics"
        }
        dict set out statics 0
    } elseif {"-statics" in $given} {
        dict set out statics $statics
    }
    if {"-nestedLoadOk" in $given} {
        if {"-nested" in $given && !$nested} {
            return -code error "conflicting values given for -nested and -nestedLoadOk"
        }
        dict set out nested 1
    } elseif {"-nested" in $given} {
        dict set out nested $nested
    }
    if {"-deleteHook" in $given} {dict set out deleteHook $deleteHook}
    return $out
}

proc ::safe::interpCreate {args} {
    ::tcl::OptKeyParse ::safe::interpCreate $args
    set opts [Options ::safe::interpCreate]
    if {"?slave?" in $::tcl::OptGiven(::safe::interpCreate)} {
        set child [interp create -safe -- $slave]
    } else {
        set child [interp create -safe]
    }
    if {[catch {Init $child $opts} msg o]} {
        catch {interp delete $child}
        return -options $o $msg
    }
    return $child
}

proc ::safe::interpInit {args} {
    ::tcl::OptKeyParse ::safe::interpIC $args
    set opts [Options ::safe::interpIC]
    if {![interp exists $slave]} {
        return -code error "\"$slave\" is not an interpreter"
    }
    Init $slave $opts
    return $slave
}

proc ::safe::interpConfigure {args} {
    set names {-accessPath -statics -nested -deleteHook}
    if {[llength $args] == 1 || [llength $args] == 2} {
        if {[string match -* [lindex $args 0]]} {
            # The error of the parser for a missing child.
            ::tcl::OptKeyParse ::safe::interpIC $args
        }
        set child [lindex $args 0]
        CheckInterp $child
        upvar #0 [State $child] state
        set all [list -accessPath $state(access_path) \
            -statics $state(staticsok) -nested $state(nestedok) \
            -deleteHook $state(cleanupHook)]
        if {[llength $args] == 1} {return $all}
        set want [lindex $args 1]
        set hits {}
        foreach n {-accessPath -statics -noStatics -nested -nestedLoadOk -deleteHook} {
            if {[string equal -nocase $n $want]} {set hits [list $n]; break}
            if {[string equal -nocase -length [string length $want] $n $want]} {lappend hits $n}
        }
        if {[llength $hits] != 1} {
            return -code error "bad option \"$want\": must be [join $names {, }]"
        }
        set n [lindex $hits 0]
        switch -- $n {
            -noStatics {set n -statics}
            -nestedLoadOk {set n -nested}
        }
        return [list $n [dict get $all $n]]
    }
    ::tcl::OptKeyParse ::safe::interpIC $args
    set opts [Options ::safe::interpIC]
    CheckInterp $slave
    Init $slave $opts 1
    return
}

proc ::safe::State {child} {
    return ::safe::S$child
}

proc ::safe::CheckInterp {child} {
    if {![info exists [State $child]]} {
        return -code error "\"$child\" is not an interpreter managed by ::safe::"
    }
}

proc ::safe::Log {child msg {type ERROR}} {
    variable Log
    if {$Log eq ""} return
    uplevel #0 [linsert $Log end "$type for slave $child : $msg"]
}

proc ::safe::setLogCmd {args} {
    variable Log
    if {[llength $args] == 0} {return $Log}
    if {[llength $args] == 1} {
        set Log [lindex $args 0]
    } else {
        set Log $args
    }
    return
}

# The access path when the options give none: tcl_library first, the
# folders of auto_path, and the folders one level below them.
proc ::safe::DefaultPath {} {
    set path {}
    if {[info exists ::tcl_library] && $::tcl_library ne ""} {lappend path $::tcl_library}
    if {[info exists ::auto_path]} {
        foreach d $::auto_path {
            if {$d ni $path} {lappend path $d}
        }
        foreach d $::auto_path {
            if {[catch {glob -nocomplain -types d -directory $d *} subs]} continue
            foreach s [lsort $subs] {
                if {$s ni $path} {lappend path $s}
            }
        }
    }
    return $path
}

# Sets up a child, or changes its options with reconfigure 1.
proc ::safe::Init {child opts {reconfigure 0}} {
    variable FileSafe
    variable FileBad
    set var [State $child]
    upvar #0 $var state
    if {!$reconfigure || ![info exists state]} {
        array set state {access_path {} staticsok 1 nestedok 0 cleanupHook {}}
        set reconfigure 0
    }
    if {[dict exists $opts statics]} {set state(staticsok) [dict get $opts statics]}
    if {[dict exists $opts nested]} {set state(nestedok) [dict get $opts nested]}
    if {[dict exists $opts deleteHook]} {set state(cleanupHook) [dict get $opts deleteHook]}
    if {[dict exists $opts accessPath] || !$reconfigure} {
        set path {}
        if {[dict exists $opts accessPath]} {set path [dict get $opts accessPath]}
        if {[llength $path] == 0} {set path [DefaultPath]}
        set uniq {}
        foreach d $path {
            if {$d ni $uniq} {lappend uniq $d}
        }
        SetPath $child $uniq
    }
    if {!$reconfigure} {
        Log $child Created NOTICE
        foreach {name target} {
            source AliasSource load AliasLoad glob AliasGlob
            encoding AliasEncoding exit interpDelete
        } {
            interp alias $child $name {} ::safe::$target $child
        }
        if {[llength [info commands ::clock]]} {
            interp alias $child clock {} ::clock
        }
        interp alias $child ::tcl::info::nameofexecutable {} ::safe::AliasExeName $child
        foreach sub $FileSafe {
            interp alias $child ::tcl::file::$sub {} ::safe::AliasFile $child $sub
        }
        foreach sub $FileBad {
            interp alias $child ::tcl::file::$sub {} ::safe::BadSubcommand $child file $sub
        }
        interp eval $child [ChildFile]
    } else {
        # A new path gives the child a new index of its commands.
        catch {interp eval $child {catch auto_reset}}
    }
    Log $child "Setting accessPath=($state(access_path)) staticsok=$state(staticsok)\
        nestedok=$state(nestedok) deletehook=($state(cleanupHook))" NOTICE
}

# The path, its tokens, and the variables of the child that name them.
proc ::safe::SetPath {child path} {
    upvar #0 [State $child] state
    set state(access_path) $path
    set map [dict create]
    set remap [dict create]
    set tokens {}
    set i 0
    foreach d $path {
        set t "\$p(:$i:)"
        dict set map $t $d
        dict set remap $d $t
        lappend tokens $t
        incr i
    }
    set state(access_path,map) $map
    set state(access_path,remap) $remap
    set state(access_path,slave) $tokens
    interp eval $child [list set auto_path $tokens]
    if {[llength $tokens]} {
        interp eval $child [list set tcl_library [lindex $tokens 0]]
    }
    Log $child "auto_path in $child has been set to $tokens" NOTICE
}

proc ::safe::interpAddToAccessPath {child path} {
    CheckInterp $child
    upvar #0 [State $child] state
    if {[dict exists $state(access_path,remap) $path]} {
        return [dict get $state(access_path,remap) $path]
    }
    SetPath $child [concat $state(access_path) [list $path]]
    return [dict get $state(access_path,remap) $path]
}

proc ::safe::interpFindInAccessPath {child path} {
    CheckInterp $child
    upvar #0 [State $child] state
    if {![dict exists $state(access_path,remap) $path]} {
        return -code error "$path not found in access path"
    }
    return [dict get $state(access_path,remap) $path]
}

proc ::safe::interpDelete {child} {
    Log $child "About to delete" NOTICE
    # The safe children of the child go first.
    foreach v [info vars ::safe::S*] {
        set c [string range $v 9 end]
        if {[llength $c] > [llength $child] && [lrange $c 0 [llength $child]-1] eq $child} {
            unset -nocomplain $v
        }
    }
    set var [State $child]
    if {[info exists $var]} {
        upvar #0 $var state
        set hook $state(cleanupHook)
        if {$hook ne ""} {
            # The hook runs once, before the child goes.
            set state(cleanupHook) {}
            if {[catch {uplevel #0 [linsert $hook end $child]} msg]} {
                Log $child "Delete hook error ($msg)"
            }
        }
        unset -nocomplain $var
    }
    if {[interp exists $child]} {interp delete $child}
    Log $child Deleted NOTICE
    return
}

# The real path of a path of the child: a token at its start becomes
# its directory.
proc ::safe::TranslatePath {child path} {
    upvar #0 [State $child] state
    dict for {t d} $state(access_path,map) {
        if {$path eq $t} {return $d}
        if {[string first "$t/" $path] == 0} {
            return $d[string range $path [string length $t] end]
        }
    }
    return $path
}

# Checks that a real file is in a directory of the access path.
proc ::safe::DirInPath {child dir} {
    upvar #0 [State $child] state
    return [expr {$dir in $state(access_path)}]
}

proc ::safe::AliasSource {child args} {
    set argc [llength $args]
    set enc {}
    if {$argc == 3 && [lindex $args 0] eq "-encoding"} {
        set enc [lindex $args 1]
        set file [lindex $args 2]
    } elseif {$argc == 1} {
        set file [lindex $args 0]
    } else {
        return -code error "wrong # args: should be \"source ?-encoding E? fileName\""
    }
    set real [TranslatePath $child $file]
    if {[file isdirectory $real]} {
        Log $child "\"$file\": is a directory"
        return -code error "permission denied"
    }
    if {![DirInPath $child [file dirname $real]]} {
        Log $child "\"$file\": not in access_path"
        return -code error "permission denied"
    }
    if {![file exists $real]} {
        Log $child "$real:no such file or directory"
        return -code error "no such file or directory"
    }
    if {[catch {
        set f [open $real]
        if {$enc ne ""} {fconfigure $f -encoding $enc}
        set text [read $f]
        close $f
    } msg]} {
        catch {close $f}
        Log $child $msg
        return -code error "permission denied"
    }
    set code [catch {interp eval $child $text} r o]
    if {$code == 2} {
        set level [dict get $o -level]
        return -level $level -code [dict get $o -code] $r
    }
    if {$code == 1} {
        Log $child $r
    }
    return -options [dict remove $o -level] -level 1 $r
}

proc ::safe::AliasLoad {child file args} {
    upvar #0 [State $child] state
    set target [lindex $args 1]
    if {$target ne "" && !$state(nestedok)} {
        Log $child "loading to a sub interp (nestedok) disabled"
        return -code error "permission denied (nested load)"
    }
    if {$file eq ""} {
        if {!$state(staticsok)} {
            Log $child "static packages loading disabled"
            return -code error "permission denied (static package)"
        }
        return -code error "load of binary library for package [lindex $args 0] failed:\
            can't use package in a safe interpreter"
    }
    set real [TranslatePath $child $file]
    if {![DirInPath $child [file dirname $real]]} {
        Log $child "\"$file\": not in access_path"
        return -code error "permission denied"
    }
    return -code error "permission denied"
}

proc ::safe::AliasExeName {child} {
    return ""
}

proc ::safe::AliasEncoding {child args} {
    if {[llength $args] >= 2 &&
            [string length [lindex $args 0]] >= 1 &&
            [string equal -length [string length [lindex $args 0]] [lindex $args 0] system]} {
        return -code error "wrong # args: should be \"encoding system\""
    }
    if {[catch {::encoding {*}$args} r]} {
        return -code error $r
    }
    return $r
}

# The file subcommands that read no file. A name that starts with ~ is
# a plain name.
proc ::safe::AliasFile {child sub args} {
    set plain {}
    foreach a $args {
        if {[string match ~* $a]} {set a ./$a}
        lappend plain $a
    }
    if {[catch {::file $sub {*}$plain} r]} {
        return -code error [string map [list ./~ ~] $r]
    }
    if {$sub eq "tail" && [string match ~* $r]} {set r ./$r}
    if {$sub eq "dirname"} {
        if {$r eq "./" || $r eq "."} {return .}
    }
    return $r
}

proc ::safe::BadSubcommand {child command sub args} {
    return -code error "not allowed to invoke subcommand $sub of $command"
}

# glob for a child: only with -directory in the access path, and each
# result in a directory of the access path. A subdirectory pattern with
# wildcards finds only pkgIndex.tcl files.
proc ::safe::AliasGlob {child args} {
    set nocomplain 0
    set dir ""
    set join 0
    set opts {}
    set i 0
    while {$i < [llength $args]} {
        set a [lindex $args $i]
        if {![string match -* $a]} break
        switch -glob -- $a {
            -nocomplain {set nocomplain 1}
            -join {set join 1}
            -directory {incr i; set dir [lindex $args $i]}
            -types - -path - -tails {incr i; lappend opts $a [lindex $args $i]}
            -- {incr i; break}
            default {return -code error "bad option \"$a\""}
        }
        incr i
    }
    set patterns [lrange $args $i end]
    if {$join} {set patterns [list [join $patterns /]]}
    if {$dir eq ""} {
        Log $child "Safe base rejecting glob command \"$args\": no -directory"
        if {$nocomplain} return
        return -code error "permission denied"
    }
    set real [TranslatePath $child $dir]
    if {![DirInPath $child $real]} {
        Log $child "\"$dir\": not in access_path"
        if {$nocomplain} return
        return -code error "permission denied"
    }
    set out {}
    foreach p $patterns {
        if {[string match ../* $p] || [string match */../* $p] || $p eq ".."} {
            Log $child "\"$p\": has .."
            if {$nocomplain} return
            return -code error "permission denied"
        }
        set sub [file dirname $p]
        if {$sub ne "." && [string match {*[*?[]*} $sub] && [file tail $p] ne "pkgIndex.tcl"} continue
        if {[catch {glob -nocomplain {*}$opts -directory $real $p} hits]} continue
        foreach h [lsort $hits] {
            if {![DirInPath $child [file dirname $h]]} continue
            lappend out $dir[string range $h [string length $real] end]
        }
    }
    if {[llength $out] == 0 && !$nocomplain} {
        return -code error "no files matched glob pattern \"[join $patterns]\""
    }
    return $out
}

# The file ensemble of a child: the subcommands that read no file are
# procs of the child, the others go to the aliases ::tcl::file::*.
proc ::safe::ChildFile {} {
    return {
        namespace eval ::tcl::file {}
        proc ::tcl::file::separator {{name ""}} {return /}
        proc ::tcl::file::pathtype {name} {
            if {[string match /* $name] || [string match ~* $name]} {return absolute}
            return relative
        }
        proc ::tcl::file::split {name} {
            set out {}
            if {[string match /* $name]} {lappend out /}
            foreach part [::split $name /] {
                if {$part eq ""} continue
                if {[llength $out] && [string match ~* $part]} {set part ./$part}
                lappend out $part
            }
            return $out
        }
        proc ::tcl::file::join {name args} {
            set out ""
            foreach part [linsert $args 0 $name] {
                if {$out ne "" && [string match ./~* $part]} {
                    set part [string range $part 2 end]
                    set out [string trimright $out /]/$part
                    continue
                }
                if {[string match /* $part] || [string match ~* $part] || $out eq ""} {
                    set out $part
                } elseif {$part ne ""} {
                    set out [string trimright $out /]/$part
                }
            }
            regsub -all {/+} $out / out
            if {$out ne "/"} {set out [string trimright $out /]}
            return $out
        }
        proc ::file {{cmd ""} args} {
            set subs {atime attributes copy delete dirname executable exists
                extension isdirectory isfile join link lstat mkdir mtime
                nativename normalize owned pathtype readable readlink rename
                rootname separator size split stat tail tempfile type volumes
                writable}
            if {$cmd eq ""} {
                return -code error "wrong # args: should be \"file subcommand ?arg ...?\""
            }
            set hits [lsearch -all -inline -glob $subs [string map {* \\* ? \\? [ \\[} $cmd]*]
            if {$cmd in $subs} {set hits [list $cmd]}
            if {[llength $hits] != 1} {
                return -code error "unknown or ambiguous subcommand \"$cmd\": must be\
                    [join [lrange $subs 0 end-1] {, }], or [lindex $subs end]"
            }
            return [uplevel 1 [list ::tcl::file::[lindex $hits 0] {*}$args]]
        }
    }
}

package provide safe 0.10
