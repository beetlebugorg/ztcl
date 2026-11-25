# The tcllib names of the module zt::json: the packages json and
# json::write, over the native parser and writer of zt::json.
#
# json::json2dict keeps the text of each number, gives "null" for a
# null, and accepts the numbers "1." and ".1", as tcllib does. Inputs that tcllib accepts and RFC 8259 rejects,
# and the messages of syntax errors, are listed in docs/modules/json.md.
#
# SPDX-License-Identifier: BSD-2-Clause

# The aliases json and json::write run this script once each. The second
# run keeps the state of the first.
if {[info exists ::json::write::indented]} {
    return
}

namespace eval ::json {
    namespace export json2dict many-json2dict validate list2json string2json
}

proc ::json::json2dict {jsonText} {
    ::zt::json::_compat $jsonText
}

proc ::json::many-json2dict {jsonText {max -1}} {
    if {$max == 0} {
        return -code error "Bad limit 0 of json entities to extract."
    }
    set all [::zt::json::_many $jsonText]
    if {$max < 0} {
        return $all
    }
    if {$max > [llength $all]} {
        return -code error "Bad limit $max of json entities to extract, found only [llength $all]."
    }
    lrange $all 0 [expr {$max - 1}]
}

proc ::json::validate {jsonText} {
    expr {![catch {::zt::json::_compat $jsonText}]}
}

proc ::json::list2json {listValue} {
    return "\[[join $listValue ,]\]"
}

proc ::json::string2json {str} {
    ::zt::json string $str
}

namespace eval ::json::write {
    variable indented 1
    variable aligned 1
    namespace export indented aligned string array array-strings object object-strings
    namespace ensemble create
}

proc ::json::write::indented {args} {
    variable indented
    variable aligned
    if {[llength $args] > 1} {
        return -code error {wrong # args: should be "json::write indented ?bool?"}
    }
    if {[llength $args] == 1} {
        set indented [lindex $args 0]
        if {!$indented && $aligned} {
            set aligned 0
        }
    }
    return $indented
}

proc ::json::write::aligned {args} {
    variable indented
    variable aligned
    if {[llength $args] > 1} {
        return -code error {wrong # args: should be "json::write aligned ?bool?"}
    }
    if {[llength $args] == 1} {
        set aligned [lindex $args 0]
        if {$aligned && !$indented} {
            set indented 1
        }
    }
    return $aligned
}

proc ::json::write::string {args} {
    if {[llength $args] != 1} {
        return -code error {wrong # args: should be "json::write string s"}
    }
    ::zt::json string [lindex $args 0]
}

proc ::json::write::array {args} {
    return "\[[join $args ,]\]"
}

proc ::json::write::array-strings {args} {
    set out {}
    foreach a $args {
        lappend out [::zt::json string $a]
    }
    return "\[[join $out ,]\]"
}

proc ::json::write::object {args} {
    variable indented
    variable aligned
    if {[llength $args] % 2} {
        return -code error {wrong # args, expected an even number of arguments}
    }
    ::zt::json::_wobject $indented $aligned $args
}

proc ::json::write::object-strings {args} {
    if {[llength $args] % 2} {
        return -code error {wrong # args, expected an even number of arguments}
    }
    set out {}
    foreach {k v} $args {
        lappend out $k [::zt::json string $v]
    }
    object {*}$out
}
