# Builds the PDF of the book with ztcl::typeset and ztcl::pdf.
#
#   ztcl --allow channels,file,exec --exec-allow sh --tclsh book/build.tcl ZTCL OUT.pdf
#
# ZTCL is the ztcl binary that runs the examples. `zig build book` runs
# this script with the runner of the same build. Each code block with the
# flag `run` runs at build time: a `sh` block runs each `$ ` line in
# book/examples with ZTCL first in PATH, and a `tcl` block runs as a
# script. The build fails when an output differs from the text.
#
# SPDX-License-Identifier: BSD-2-Clause

package require ztcl::pdf
package require ztcl::typeset

if {[llength $argv] != 2} {
    puts stderr "usage: ztcl build.tcl ZTCL OUT.pdf"
    exit 2
}
lassign $argv ztcl out
set ztcl [file normalize $ztcl]
set root [file dirname [file normalize [info script]]]

proc slurp {path {binary 0}} {
    set f [open $path rb]
    if {!$binary} { fconfigure $f -translation auto -encoding utf-8 }
    set data [read $f]
    close $f
    return $data
}

# The chapters of the book: the file and the chapter number.
set chapters {
    chapters/13-tooling.md 13
}

# The fonts (SIL Open Font License 1.1, book/fonts/OFL.txt).
set doc [ztcl::pdf create]
set fonts {}
foreach {key file} {
    serif      SourceSerif4-Regular.ttf
    italic     SourceSerif4-Italic.ttf
    bold       SourceSerif4-Semibold.ttf
    bolditalic SourceSerif4-SemiboldItalic.ttf
    sans       SourceSans3-Regular.ttf
    sansbold   SourceSans3-Semibold.ttf
    mono       SourceCodePro-Regular.ttf
    monobold   SourceCodePro-Semibold.ttf
} {
    dict set fonts $key [ztcl::pdf font $doc [slurp [file join $root fonts $file] 1]]
}
ztcl::pdf info $doc Title "ztcl: The Fast, Safe Scripting Platform (sample chapter)"
ztcl::pdf info $doc Subject "Part II, Tooling"

# Runs one example. The result is the output, with the error output.
set runs 0
proc run {lang code} {
    global ztcl root out runs
    incr runs
    set dir [file join $root examples]
    switch -- $lang {
        sh {
            set bin [file dirname $ztcl]
            set script "PATH='$bin':\"\$PATH\"; cd '$dir' || exit 1\n{ $code\n} 2>&1\nexit 0"
            return [exec sh -c $script]
        }
        tcl {
            set tmp [file join [file dirname [file normalize $out]] "run-$runs.tcl"]
            set f [open $tmp w]
            puts $f $code
            close $f
            set status [catch {exec sh -c "cd '$dir' && '$ztcl' '$tmp' 2>&1"} result]
            file delete $tmp
            return $result
        }
        default {
            error "no runner for the language \"$lang\""
        }
    }
}

set list {}
foreach {file number} $chapters {
    lappend list [list $file $number [slurp [file join $root $file]]]
}
set stats [ztcl::typeset book $doc $list -fonts $fonts -run run]

set f [open $out wb]
puts -nonewline $f [ztcl::pdf bytes $doc]
close $f

set messages [dict get $stats messages]
dict unset stats messages
puts "book: $out"
puts "book: [dict get $stats pages] pages, [dict get $stats lines] lines, [dict get $stats hyphens] hyphens, [dict get $stats checked] examples checked"
if {[llength $messages] > 0} {
    foreach m $messages { puts stderr $m }
    exit 1
}
