# The opt package 0.4.9: the argument parser of the Tcl library, with
# ::tcl::OptProc. Tcl has no manual page for it, so the behavior
# follows the tests of opt.test of Tcl 8.6. src/tcllib.zig has this
# file.
#
# A description is a list of items. An item is a flag (-name) or a
# parameter (name, or ?name? when it is optional), with a type, a
# default value, and a help text:
#
#   {-flag}                     a flag of type boolflag, false
#   {-name -boolean true}       a flag with a value of a type
#   {name -choice {a b} help}   a value from a list
#   {name -string help}         a required string
#   {?name? 7 help}             an optional value, the type from 7
#   {args -list {} help}        the rest of the words
#
# The parse goes through the items in order. A parameter takes the next
# word. Before a parameter that follows a flag in the description, and
# at the end, the words that start with - are flags: a prefix of a flag
# name, in any case, or -- to end the flags. An optional parameter
# leaves a word that does not fit its type. -help gives the usage.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::tcl {
    variable OptDescN 0
    variable OptDesc
    array set OptDesc {}
    namespace export OptKeyRegister OptKeyDelete OptKeyError OptKeyParse \
        OptProc OptProcArgGiven OptParse Lempty Lget Lvarset Lvarset1 \
        Lvarincr Lvarpop Lassign SetMax SetMin
}

# The types that a description names with -type.
proc ::tcl::OptTypes {} {
    return {any string int float boolean boolflag list choice script name}
}

# Parses one item into a dict: name var kind (flag or param), optional,
# type, default, choices, and help.
proc ::tcl::OptItem {item} {
    set name [lindex $item 0]
    set d [dict create name $name help "" choices {} default ""]
    if {[string match -* $name]} {
        dict set d kind flag
        dict set d optional 1
        dict set d var [string range $name 1 end]
    } elseif {[regexp {^\?(.*)\?$} $name -> v]} {
        dict set d kind param
        dict set d optional 1
        dict set d var $v
    } else {
        dict set d kind param
        dict set d optional [expr {$name eq "args"}]
        dict set d var $name
    }
    set rest [lrange $item 1 end]
    set t [lindex $rest 0]
    if {[llength $rest] == 0} {
        if {[dict get $d kind] eq "flag"} {
            dict set d type boolflag
            dict set d default 0
        } else {
            dict set d type any
        }
    } elseif {[string match -* $t] && [string range $t 1 end] in [OptTypes]} {
        set type [string range $t 1 end]
        dict set d type $type
        set more [lrange $rest 1 end]
        if {$type eq "choice"} {
            dict set d choices [lindex $more 0]
            dict set d default [lindex [lindex $more 0] 0]
            dict set d help [lindex $more 1]
        } elseif {[llength $more] >= 2} {
            dict set d default [lindex $more 0]
            dict set d help [lindex $more 1]
        } elseif {[llength $more] == 1} {
            set v [lindex $more 0]
            if {$type ni {string any script name} && ![catch {OptCheckType $v $type}]} {
                dict set d default $v
            } else {
                dict set d help $v
            }
        }
        if {$type eq "boolflag" && [dict get $d default] eq ""} {dict set d default 0}
    } else {
        # A default value with no type: the type comes from the value.
        if {[string is integer -strict $t]} {
            dict set d type int
        } elseif {[string is double -strict $t]} {
            dict set d type float
        } elseif {[string is boolean -strict $t]} {
            dict set d type boolean
        } elseif {[llength $t] > 1} {
            dict set d type list
        } else {
            dict set d type any
        }
        dict set d default $t
        dict set d help [lindex $rest 1]
    }
    return $d
}

proc ::tcl::OptKeyRegister {desc {key ""}} {
    variable OptDesc
    variable OptDescN
    if {$key eq ""} {
        while {[info exists OptDesc($OptDescN)]} {incr OptDescN}
        set key $OptDescN
        incr OptDescN
    }
    set items {}
    foreach item $desc {lappend items [OptItem $item]}
    set OptDesc($key) $items
    return $key
}

proc ::tcl::OptKeyDelete {key} {
    variable OptDesc
    unset OptDesc($key)
    return
}

# The value shown in the usage: a choice list, or the default.
proc ::tcl::OptShown {d} {
    if {[dict get $d type] eq "choice"} {return "([dict get $d choices])"}
    set v [dict get $d default]
    switch -- [dict get $d type] {
        boolflag {set v [expr {$v ? "true" : "false"}]}
    }
    return "($v)"
}

# The lines of a table of items, with a column for each field.
proc ::tcl::OptTable {items {header 1}} {
    set nw 0
    set tw 0
    set vw 0
    if {$header} {
        set nw [string length Var/FlagName]
        set tw [string length Type]
        set vw [string length Value]
    }
    foreach d $items {
        if {[string length [dict get $d name]] > $nw} {set nw [string length [dict get $d name]]}
        if {[string length [dict get $d type]] > $tw} {set tw [string length [dict get $d type]]}
        if {[dict get $d type] ne "choice"} {
            set n [string length [OptShown $d]]
            if {$n > $vw} {set vw $n}
        }
    }
    set lines {}
    if {$header} {
        lappend lines [format "%-*s %-*s %-*s %s" $nw Var/FlagName $tw Type $vw Value Help]
        lappend lines [format "%-*s %-*s %-*s %s" $nw ------------ $tw ---- $vw ----- ----]
        lappend lines [format "%-*s%s)" [expr {$nw + $tw + $vw + 3}] (-help "gives this help"]
    }
    foreach d $items {
        lappend lines [string trimright [format "%-*s %-*s %-*s %s" \
            $nw [dict get $d name] $tw [dict get $d type] $vw [OptShown $d] [dict get $d help]]]
    }
    set out {}
    foreach l $lines {lappend out "    $l"}
    return [join $out \n]
}

proc ::tcl::OptOne {d} {
    return [string trimright "[dict get $d name] [dict get $d type] [OptShown $d] [dict get $d help]"]
}

proc ::tcl::OptKeyError {prefix key} {
    variable OptDesc
    return -code error "$prefix\n[OptTable $OptDesc($key)]"
}

# Gives the value of a word for a type, or an error.
proc ::tcl::OptCheckType {arg type {choices {}}} {
    switch -exact -- $type {
        int {
            if {![string is integer -strict $arg]} {error "not an integer"}
            return $arg
        }
        float {return [expr {double($arg)}]}
        boolean - boolflag {
            if {![string is boolean -strict $arg]} {error "not a boolean"}
            return [expr {$arg ? 1 : 0}]
        }
        list {
            if {[catch {llength $arg}]} {error "not a list"}
            return $arg
        }
        choice {
            if {$arg ni $choices} {error "not one of $choices"}
            return $arg
        }
        string - name - script {
            if {[string match -* $arg]} {error "starts with -"}
            return $arg
        }
        default {return $arg}
    }
}

# The flag item of a word, or {} when no flag fits. An ambiguous prefix
# is an error.
proc ::tcl::OptFindFlag {items word} {
    set hits {}
    foreach d $items {
        if {[dict get $d kind] ne "flag"} continue
        set n [dict get $d name]
        if {[string equal -nocase $n $word]} {return $d}
        if {[string equal -nocase -length [string length $word] $n $word]} {lappend hits $d}
    }
    if {[llength $hits] == 1} {return [lindex $hits 0]}
    if {[llength $hits] > 1} {
        return -code error "ambigous option \"$word\", choose from:\n[OptTable $hits 0]"
    }
    return
}

# Sets the variables of a description from the words, in the frame
# `level`.
proc ::tcl::OptDoParse {key arglist level} {
    variable OptDesc
    set items $OptDesc($key)
    set values [dict create]
    set given {}
    set flagsDone 0
    set seenFlag 0
    set i 0
    set n [llength $arglist]
    set usage [list return -code error "Usage information:\n[OptTable $items]"]
    foreach d $items {
        if {[dict get $d kind] eq "flag"} {
            set seenFlag 1
            continue
        }
        if {$seenFlag} {
            set i [OptFlags $items $arglist $i values given flagsDone $usage]
        }
        set var [dict get $d var]
        if {$var eq "args" && [dict get $d optional]} {
            if {$i < $n} {
                dict set values args [lrange $arglist $i end]
                lappend given args
                set i $n
            }
            continue
        }
        if {$i < $n && [string equal -nocase [lindex $arglist $i] -help]} {{*}$usage}
        if {$i >= $n} {
            if {[dict get $d optional]} continue
            return -code error "no value given for parameter \"[dict get $d name]\"\
                (use -help for full usage) :\n    [OptOne $d]"
        }
        set w [lindex $arglist $i]
        if {[catch {OptCheckType $w [dict get $d type] [dict get $d choices]} v]} {
            if {[dict get $d optional]} continue
            return -code error "bad value \"$w\" for parameter\n    [OptOne $d]"
        }
        dict set values $var $v
        lappend given [dict get $d name]
        incr i
    }
    set i [OptFlags $items $arglist $i values given flagsDone $usage]
    if {$i < $n} {
        return -code error "too many arguments (unexpected argument(s):\
            [lrange $arglist $i end]), usage:\n[OptTable $items]"
    }
    foreach d $items {
        set var [dict get $d var]
        if {[dict exists $values $var]} {
            set v [dict get $values $var]
        } else {
            set v [dict get $d default]
            if {[dict get $d type] in {boolean boolflag} && $v ne ""} {
                set v [expr {$v ? 1 : 0}]
            } elseif {[dict get $d type] eq "float" && $v ne ""} {
                set v [expr {double($v)}]
            }
        }
        uplevel $level [list set $var $v]
    }
    uplevel $level [list set ::tcl::OptGiven($key) $given]
    return
}

# Reads the flags at word i. Gives the index of the first word that is
# not a flag.
proc ::tcl::OptFlags {items arglist i valuesVar givenVar doneVar usage} {
    upvar 1 $valuesVar values $givenVar given $doneVar done
    set n [llength $arglist]
    while {!$done && $i < $n} {
        set w [lindex $arglist $i]
        if {![string match -* $w]} break
        if {$w eq "--"} {
            set done 1
            incr i
            break
        }
        if {[string equal -nocase $w -help]} {{*}$usage}
        set d [OptFindFlag $items $w]
        if {$d eq ""} break
        incr i
        if {[dict get $d type] eq "boolflag"} {
            dict set values [dict get $d var] 1
        } else {
            if {$i >= $n} {
                return -code error "no value given for parameter \"[dict get $d name]\"\
                    (use -help for full usage) :\n    [OptOne $d]"
            }
            set w [lindex $arglist $i]
            if {[catch {OptCheckType $w [dict get $d type] [dict get $d choices]} v]} {
                return -code error "bad value \"$w\" for parameter\n    [OptOne $d]"
            }
            dict set values [dict get $d var] $v
            incr i
        }
        lappend given [dict get $d name]
    }
    return $i
}

proc ::tcl::OptKeyParse {key arglist} {
    variable OptGiven
    OptDoParse $key $arglist 2
}

proc ::tcl::OptParse {desc arglist} {
    set key [OptKeyRegister $desc]
    try {
        OptDoParse $key $arglist 2
    } finally {
        OptKeyDelete $key
    }
}

proc ::tcl::OptProc {name desc body} {
    set key [OptKeyRegister $desc $name]
    uplevel 1 [list ::proc $name args \
        "set Args \[::tcl::OptKeyParse [list $key] \$args\]\n$body"]
}

# 1 when the last parse of the calling proc had the parameter.
proc ::tcl::OptProcArgGiven {argname} {
    variable OptGiven
    set key [uplevel 1 {lindex [info level 0] 0}]
    set key [namespace tail $key]
    foreach k [list [uplevel 1 {lindex [info level 0] 0}] $key] {
        if {[info exists OptGiven($k)]} {
            foreach g $OptGiven($k) {
                if {[string equal -nocase $g $argname]} {return 1}
            }
            return 0
        }
    }
    return 0
}

# ---- list and variable helpers ----

proc ::tcl::Lempty {list} {
    return [expr {[llength $list] == 0}]
}

proc ::tcl::Lget {list indexes} {
    return [lindex $list {*}$indexes]
}

proc ::tcl::Lvarset {listVar indexes value} {
    upvar 1 $listVar l
    lset l {*}$indexes $value
}

proc ::tcl::Lvarset1 {listVar index value} {
    upvar 1 $listVar l
    while {[llength $l] < $index} {lappend l {}}
    if {[llength $l] == $index} {lappend l $value} else {lset l $index $value}
    return $l
}

proc ::tcl::Lvarincr {listVar indexes {by 1}} {
    upvar 1 $listVar l
    lset l {*}$indexes [expr {[lindex $l {*}$indexes] + $by}]
}

proc ::tcl::Lvarpop {listVar} {
    upvar 1 $listVar l
    set first [lindex $l 0]
    set l [lrange $l 1 end]
    return $first
}

proc ::tcl::Lassign {list args} {
    set n 0
    foreach v $args {
        if {$n >= [llength $list]} break
        uplevel 1 [list set $v [lindex $list $n]]
        incr n
    }
    return $n
}

proc ::tcl::SetMax {varName value} {
    upvar 1 $varName v
    if {![info exists v] || $value > $v} {set v $value}
    return $v
}

proc ::tcl::SetMin {varName value} {
    upvar 1 $varName v
    if {![info exists v] || $value < $v} {set v $value}
    return $v
}

package provide opt 0.4.9
