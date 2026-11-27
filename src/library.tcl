# The library commands of Tcl for an interpreter with the capability
# package: auto_path, the handler of `package unknown` that reads the
# pkgIndex.tcl files of auto_path, auto_load with tclIndex files,
# auto_execok, auto_qualify, history, and the Tcl modules (tcl::tm).
# The commands follow the manual pages library.n, package.n, and tm.n
# of Tcl 8.6. src/interp.zig evaluates
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

# ---- tcl::tm: Tcl modules ----

# The module path of tm.n: a list of folders, searched from the first.
# A module is a file NAME-VERSION.tm below a folder of the path, with
# each :: of the package name as a folder separator.
namespace eval ::tcl::tm {
    variable paths {}
    namespace export path roots
}

proc ::tcl::tm::path {{sub ""} args} {
    switch -exact -- $sub {
        add {return [Add {*}$args]}
        remove {
            variable paths
            foreach p $args {
                set i [lsearch -exact $paths $p]
                if {$i >= 0} {set paths [lreplace $paths $i $i]}
            }
            return
        }
        list {
            if {[llength $args]} {
                return -code error "wrong # args: should be \"::tcl::tm::path list\""
            }
            variable paths
            return $paths
        }
        default {
            return -code error "unknown or ambiguous subcommand \"$sub\": must be add, list, or remove"
        }
    }
}

# Adds each folder at the head of the path. A folder that is an
# ancestor or a subfolder of another folder of the path is an error,
# and then no folder goes in.
proc ::tcl::tm::Add {args} {
    variable paths
    set new $paths
    foreach p $args {
        if {$p in $new} continue
        foreach q $new {
            if {[string match $p/* $q]} {
                return -code error "$p is ancestor of existing module path $q."
            }
            if {[string match $q/* $p]} {
                return -code error "$p is subdirectory of existing module path $q."
            }
        }
        set new [linsert $new 0 $p]
    }
    set paths $new
    return
}

# Adds ROOT/tclX/site-tcl and ROOT/tclX/X.y for each y up to the minor
# version of Tcl, for each root.
proc ::tcl::tm::roots {args} {
    if {[llength $args] != 1} {
        return -code error "wrong # args: should be \"::tcl::tm::roots paths\""
    }
    regexp {^(\d+)\.(\d+)} [info tclversion] -> major minor
    foreach root [lindex $args 0] {
        if {[llength [info commands ::file]]} {catch {set root [file normalize $root]}}
        set base $root/tcl$major
        set list [list $base/site-tcl]
        for {set i 0} {$i <= $minor} {incr i} {lappend list $base/$major.$i}
        foreach p [lreverse $list] {Add $p}
    }
    return
}

# The handler of package unknown: an ifneeded script for each module of
# the name on the path, then the handler before it when none fits.
proc ::tcl::tm::UnknownHandler {original name args} {
    variable paths
    set found 0
    if {[llength [info commands ::glob]]} {
        set partial [string map {:: /} $name]
        set dir [file dirname $partial]
        set tail [file tail $partial]
        foreach p $paths {
            set d [expr {$dir eq "." ? $p : "$p/$dir"}]
            if {[catch {glob -nocomplain -directory $d -types f -- $tail-*.tm} files]} continue
            foreach f $files {
                if {![regexp -- {-([[:digit:]][^-]*)\.tm$} $f -> version]} continue
                if {[catch {package vcompare $version 0}]} continue
                if {[package ifneeded $name $version] eq ""} {
                    package ifneeded $name $version [list source -encoding utf-8 $f]
                }
                if {[llength $args] == 0 || [package vsatisfies $version {*}$args]} {set found 1}
            }
        }
    }
    if {!$found && [llength $original]} {
        uplevel 1 $original [list $name] $args
    }
}

# The default paths: the roots next to tcl_library and the program,
# and the folders of the variables TCLX.y_TM_PATH and TCLX_y_TM_PATH.
proc ::tcl::tm::Defaults {} {
    if {![llength [info commands ::file]]} return
    regexp {^(\d+)\.(\d+)} [info tclversion] -> major minor
    set roots {}
    if {[info exists ::tcl_library] && $::tcl_library ne ""} {
        lappend roots [file dirname $::tcl_library]
    }
    catch {
        set exe [info nameofexecutable]
        if {$exe ne ""} {lappend roots [file join [file dirname [file dirname $exe]] lib]}
    }
    catch {roots $roots}
    for {set i $minor} {$i >= 0} {incr i -1} {
        foreach v [list TCL${major}.${i}_TM_PATH TCL${major}_${i}_TM_PATH] {
            if {[info exists ::env($v)]} {
                catch {Add {*}[lreverse [split $::env($v) [expr {$::tcl_platform(platform) eq "windows" ? ";" : ":"}]]]}
            }
        }
    }
}
::tcl::tm::Defaults
package unknown [list ::tcl::tm::UnknownHandler [package unknown]]

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
                    if {[namespace which -command ::$bare] ne ""} {return 1}
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

# ---- pkg_mkIndex and pkg::create ----

namespace eval ::pkg {}
namespace eval ::tcl::Pkg {}

# Writes the pkgIndex.tcl file of a folder, as pkgMkIndex.n describes.
# Each file goes into a new child interpreter, which notes the packages
# that the file provides and the commands that it makes. A package
# require of the file that fails is no error in the child, and the
# commands of a package that a require loads are not the commands of
# the file. A file that fails goes again after the others, with the
# packages found so far, until a round finds no new file.
proc ::pkg_mkIndex {args} {
    set usage {pkg_mkIndex ?-direct? ?-lazy? ?-load pattern? ?-verbose? ?--? dir ?pattern ...?}
    set direct 1
    set verbose 0
    set loadPat {}
    set i 0
    for {} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        if {![string match -* $a]} break
        switch -exact -- $a {
            -- {incr i; break}
            -direct {set direct 1}
            -lazy {set direct 0}
            -verbose {set verbose 1}
            -load {incr i; set loadPat [lindex $args $i]}
            default {return -code error "unknown flag $a: should be\n$usage"}
        }
    }
    set dir [lindex $args $i]
    set patterns [lrange $args $i+1 end]
    if {$dir eq ""} {return -code error "wrong # args: should be\n$usage"}
    if {[llength $patterns] == 0} {
        set patterns [list *.tcl *[info sharedlibextension]]
    }
    set files {}
    foreach p $patterns {
        foreach f [lsort [glob -nocomplain -directory $dir -types f -tails -- $p]] {
            if {$f ne "pkgIndex.tcl" && $f ni $files} {lappend files $f}
        }
    }
    if {[llength $files] == 0} {
        return -code error "no files matched glob pattern \"[join $patterns]\""
    }
    # name version -> list of {file type commands}
    set found [dict create]
    set pending $files
    while {[llength $pending]} {
        set next {}
        foreach f $pending {
            if {[catch {::tcl::Pkg::Index $dir $f $found $loadPat} r]} {
                if {$verbose} {tclLog "warning: error while sourcing $f: $r"}
                lappend next $f
                continue
            }
            lassign $r type provided cmds
            if {$verbose} {
                tclLog "successful sourcing of $f"
                tclLog "packages provided were {$provided}"
            }
            foreach {name ver} $provided {
                dict lappend found [list $name $ver] [list $f $type $cmds]
            }
            if {$verbose} {tclLog "processed $f"}
        }
        if {[llength $next] == [llength $pending]} break
        set pending $next
    }
    set out "# Tcl package index file, version 1.1\n"
    append out "# This file is generated by the \"pkg_mkIndex\" command\n"
    append out "# and sourced either when an application starts up or\n"
    append out "# by a \"package unknown\" script.  It invokes the\n"
    append out "# \"package ifneeded\" command to set up package-related\n"
    append out "# information so that packages will be loaded automatically\n"
    append out "# in response to \"package require\" commands.  When this\n"
    append out "# script is sourced, the variable \$dir must contain the\n"
    append out "# full path name of this file's directory.\n"
    foreach key [lsort [dict keys $found]] {
        lassign $key name ver
        set opts [list -name $name -version $ver]
        foreach entry [dict get $found $key] {
            lassign $entry f type cmds
            set flag [expr {$type eq "load" ? "-load" : "-source"}]
            if {$direct} {lappend opts $flag $f} else {lappend opts $flag [list $f $cmds]}
        }
        append out "\n[::pkg::create {*}$opts]"
    }
    append out \n
    set fd [open [file join $dir pkgIndex.tcl] w]
    chan puts -nonewline $fd $out
    close $fd
    return
}

# Sources or loads one file in a new child. Gives the type, the
# packages that the file provides as a list of names and versions, and
# its commands.
proc ::tcl::Pkg::Index {dir file found loadPat} {
    set c [interp create]
    try {
        $c eval [list set ::auto_path $::auto_path]
        dict for {key entries} $found {
            lassign $key name ver
            set script {}
            foreach e $entries {
                lassign $e f type
                lappend script [list $type [file join $dir $f]]
            }
            $c eval [list package ifneeded $name $ver [join $script \n]]
        }
        foreach p [package names] {
            if {$loadPat ne "" && [string match -nocase $loadPat $p] &&
                    ![catch {package present $p} v]} {
                catch {$c eval [list package require $p $v]}
            }
        }
        $c eval {
            namespace eval ::tcl::Pkg {}
            proc ::tcl::Pkg::Commands {{ns ::}} {
                set out {}
                set pat [expr {$ns eq "::" ? "::*" : "${ns}::*"}]
                foreach cmd [info commands $pat] {
                    if {[namespace origin $cmd] eq [namespace which -command $cmd] ||
                            $ns ne "::"} {
                        lappend out $cmd
                    }
                }
                foreach child [namespace children $ns] {
                    lappend out {*}[Commands $child]
                }
                return $out
            }
            set ::tcl::Pkg::skip [::tcl::Pkg::Commands]
            set ::tcl::Pkg::required {}
            set ::tcl::Pkg::provided {}
            set ::tcl::Pkg::depth 0
            rename package ::tcl::Pkg::package
            proc ::package {sub args} {
                if {$sub eq "require"} {
                    set before [::tcl::Pkg::Commands]
                    incr ::tcl::Pkg::depth
                    set code [catch {uplevel 1 [list ::tcl::Pkg::package require {*}$args]} r]
                    incr ::tcl::Pkg::depth -1
                    foreach cmd [::tcl::Pkg::Commands] {
                        if {$cmd ni $before} {lappend ::tcl::Pkg::skip $cmd}
                    }
                    set name [lindex [lsearch -inline -not -glob $args -*] 0]
                    lappend ::tcl::Pkg::required $name
                    if {$code} return
                    return $r
                }
                if {$sub eq "provide" && [llength $args] == 2 && $::tcl::Pkg::depth == 0} {
                    lappend ::tcl::Pkg::provided {*}$args
                }
                return [uplevel 1 [list ::tcl::Pkg::package $sub {*}$args]]
            }
        }
        set path [file join $dir $file]
        set ext [info sharedlibextension]
        if {$ext ne "" && [::tcl::Pkg::CompareExtension $file $ext]} {
            set type load
            $c eval [list load $path]
        } else {
            set type source
            $c eval [list source $path]
        }
        set provided [$c eval {set ::tcl::Pkg::provided}]
        set cmds [$c eval {
            set out {}
            foreach cmd [::tcl::Pkg::Commands] {
                if {$cmd in $::tcl::Pkg::skip || [string match ::tcl::Pkg::* $cmd]} continue
                set ns [namespace qualifiers $cmd]
                set tail [namespace tail $cmd]
                if {$ns eq "" || $ns eq "::"} {
                    lappend out $tail
                    continue
                }
                foreach pat [namespace eval $ns {namespace export}] {
                    if {[string match $pat $tail]} {
                        lappend out ::[string trimleft $cmd :]
                        break
                    }
                }
            }
            lsort $out
        }]
        return [list $type $provided $cmds]
    } finally {
        interp delete $c
    }
}

# 1 when a file name ends in the extension, or in the extension and
# version numbers, as foo.so.1.2.
proc ::tcl::Pkg::CompareExtension {fileName {ext {}}} {
    if {$ext eq ""} {set ext [info sharedlibextension]}
    set root $fileName
    while {1} {
        set e [file extension $root]
        if {$e eq $ext} {return 1}
        if {![regexp {^\.[0-9]+$} $e]} {return 0}
        set root [file rootname $root]
    }
}

# The ifneeded script of a package, as a line of a pkgIndex.tcl file.
proc ::pkg::create {args} {
    set usage {::pkg::create -name packageName -version packageVersion ?-load {filename ?{procs}?}? ... ?-source {filename ?{procs}?}? ...}
    if {[llength $args] == 0} {
        return -code error "wrong # args: should be \"$usage\""
    }
    set name {}
    set version {}
    set loads {}
    set sources {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set o [lindex $args $i]
        if {$o ni {-name -version -load -source}} {
            return -code error "unknown option \"[lindex $args $i+1]\": should be \"$usage\""
        }
        if {$i + 1 >= [llength $args]} {
            return -code error "value for \"$o\" missing: should be \"$usage\""
        }
        set v [lindex $args [incr i]]
        switch -- $o {
            -name {set name $v}
            -version {set version $v}
            -load {lappend loads $v}
            -source {lappend sources $v}
        }
    }
    if {$name eq ""} {return -code error "value for \"-name\" missing: should be \"$usage\""}
    if {$version eq ""} {return -code error "value for \"-version\" missing: should be \"$usage\""}
    if {[llength $loads] == 0 && [llength $sources] == 0} {
        return -code error "at least one of -load and -source must be given"
    }
    set lines {}
    set lazy {}
    foreach l $loads {
        if {[llength $l] > 1} {
            lappend lazy [list [lindex $l 0] load [lindex $l 1]]
        } else {
            lappend lines "\[list load \[file join \$dir [list [lindex $l 0]]\]\]"
        }
    }
    foreach s $sources {
        if {[llength $s] > 1} {
            lappend lazy [list [lindex $s 0] source [lindex $s 1]]
        } else {
            lappend lines "\[list source \[file join \$dir [list [lindex $s 0]]\]\]"
        }
    }
    if {[llength $lazy]} {
        lappend lines "\[list tclPkgSetup \$dir [list $name] [list $version] [list $lazy]\]"
    }
    return "package ifneeded [list $name] [list $version] [join $lines {\n}]"
}

# ---- auto_mkindex ----

# Writes the tclIndex file of a folder, as library.n describes. Each
# file of the patterns is read as Tcl text, and no command of it runs.
# The parse goes through the commands of the text: proc defines a
# command, namespace eval goes into its body with that namespace, and
# namespace ensemble create defines the command of the namespace. A
# command of auto_mkindex_parser::command runs its handler on the
# words. Each other command is skipped.
namespace eval ::auto_mkindex_parser {
    variable initCommands {}
    variable commands
    array set commands {}
    variable index {}
    variable scriptFile {}
    variable contextStack {}
}

proc ::auto_mkindex {dir args} {
    if {[llength $args] == 0} {set args *.tcl}
    set out "# Tcl autoload index file, version 2.0\n"
    append out "# This file is generated by the \"auto_mkindex\" command\n"
    append out "# and sourced to set up indexing information for one or\n"
    append out "# more commands.  Typically each line is a command that\n"
    append out "# sets an element in the auto_index array, where the\n"
    append out "# element name is the name of a command and the value is\n"
    append out "# a script that loads the command.\n\n"
    set files {}
    foreach p $args {
        foreach f [lsort [glob -nocomplain -directory $dir -tails -- $p]] {
            if {$f ni $files} {lappend files $f}
        }
    }
    foreach f $files {
        append out [::auto_mkindex_parser::mkindex $dir $f]
    }
    set fd [open [file join $dir tclIndex] w]
    chan puts -nonewline $fd $out
    close $fd
    return
}

# Gives the lines of the index of one file.
proc ::auto_mkindex_parser::mkindex {dir file} {
    variable index
    variable scriptFile
    variable contextStack
    set index {}
    set scriptFile $file
    set contextStack {::}
    set fd [open [file join $dir $file]]
    fconfigure $fd -encoding utf-8
    set text [read $fd]
    close $fd
    Parse $text
    return $index
}

# The full name of a command that the file defines in the current
# namespace. A global name has no leading ::.
proc ::auto_mkindex_parser::fullname {name} {
    variable contextStack
    set ns [lindex $contextStack end]
    regsub -all {:::+} $name :: name
    if {[string match ::* $name]} {
        set rest [string range $name 2 end]
        if {[string first :: $rest] >= 0} {return $name}
        return $rest
    }
    if {$ns eq "::"} {
        if {[string first :: $name] >= 0} {return ::$name}
        return $name
    }
    return ${ns}::$name
}

proc ::auto_mkindex_parser::Add {name} {
    variable index
    variable scriptFile
    append index [list set auto_index([fullname $name])] \
        " \[list source -encoding utf-8 \[file join \$dir [file split $scriptFile]\]\]\n"
}

# Splits a text into commands at the ends of lines, with the comments
# left out.
proc ::auto_mkindex_parser::Commands {text} {
    set out {}
    set cmd ""
    foreach line [split $text \n] {
        if {$cmd eq "" && [string match #* [string trimleft $line]]} continue
        append cmd $line \n
        if {[info complete $cmd]} {
            if {[string trim $cmd] ne ""} {lappend out $cmd}
            set cmd ""
        }
    }
    return $out
}

proc ::auto_mkindex_parser::Parse {text} {
    variable commands
    variable contextStack
    foreach cmd [Commands $text] {
        if {[catch {lrange $cmd 0 end} words] || [llength $words] == 0} continue
        set first [lindex $words 0]
        set ns [lindex $contextStack end]
        set key [string trimleft [fullname $first] :]
        if {[info exists commands($key)]} {
            catch {::auto_mkindex_parser::Handler_$commands($key) {*}[lrange $words 1 end]}
            continue
        }
        switch -exact -- [string trimleft $first :] {
            proc {
                if {[llength $words] == 4} {Add [lindex $words 1]}
            }
            namespace {
                set sub [lindex $words 1]
                if {$sub eq "eval" && [llength $words] >= 4} {
                    set name [string trimright [lindex $words 2] :]
                    if {$name eq ""} {set name ::}
                    if {![string match ::* $name]} {
                        set name [expr {$ns eq "::" ? "::$name" : "${ns}::$name"}]
                    }
                    lappend contextStack $name
                    Parse [join [lrange $words 3 end]]
                    set contextStack [lrange $contextStack 0 end-1]
                } elseif {$sub eq "ensemble" && [lindex $words 2] eq "create"} {
                    set opts [lrange $words 3 end]
                    set i [lsearch -exact $opts -command]
                    if {$i >= 0} {
                        Add [lindex $opts $i+1]
                    } elseif {$ns ne "::"} {
                        Add ::[string trimleft $ns :]
                    }
                }
            }
        }
    }
}

# Adds a handler for a command of the files: the handler runs with the
# words of the command, in this namespace.
proc ::auto_mkindex_parser::command {name arglist body} {
    variable commands
    set key [string trimleft $name :]
    set id [array size commands]
    set commands($key) $id
    proc ::auto_mkindex_parser::Handler_$id $arglist $body
}

# A script of setup commands for the parse. The parse runs no command
# of a file, so the script is kept and runs nowhere.
proc ::auto_mkindex_parser::slavehook {cmd} {
    variable initCommands
    lappend initCommands $cmd
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
