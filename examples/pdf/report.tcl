# A report page: a title, a justified paragraph, a table, and a bar
# chart made of rectangles and lines.
source [file join [file dirname [info script]] common.tcl]
set out [expr {$argc > 0 ? [lindex $argv 0] : "report.pdf"}]

set doc [ztcl::pdf create]
set F [loadFonts $doc]
set tf [ztcl::typeset font load [slurp [file join [file dirname [info script]] .. .. book fonts SourceSerif4-Regular.ttf]]]
ztcl::pdf info $doc Title "Quarterly build report"
set p [ztcl::pdf page $doc]
set left 72
set width 451

ztcl::pdf text $doc $p [dict get $F sansbold] 20 $left 760 "Quarterly build report"
ztcl::pdf text $doc $p [dict get $F sans] 10 $left 742 "Q3 2026 · example data" -color {0.45 0.45 0.45}

set text "The build farm ran more jobs each month of the quarter. The median time of a job went down after the cache change in August, and the count of failed jobs stayed low. The table and the chart below give the numbers of each month."
set y 712
foreach line [ztcl::typeset break $text -width $width -font $tf -size 10.5] {
    foreach {x word} [dict get $line words] {
        ztcl::pdf text $doc $p [dict get $F serif] 10.5 [expr {$left + $x}] $y $word
    }
    set y [expr {$y - 14}]
}

set data {July 1840 9.2 31 August 2210 7.4 24 September 2630 6.9 19}
set y [expr {$y - 20}]
set heads {Month Jobs "Median minutes" Failed}
set xs {72 250 380 523}
foreach h $heads x $xs i {0 1 2 3} {
    if {$i == 0} {
        ztcl::pdf text $doc $p [dict get $F sansbold] 9.5 $x $y $h
    } else {
        rightText $doc $p [dict get $F sansbold] 9.5 $x $y $h
    }
}
ztcl::pdf line $doc $p $left [expr {$y - 6}] [expr {$left + $width}] [expr {$y - 6}] -width 0.8
set y [expr {$y - 22}]
foreach {m jobs med fail} $data {
    ztcl::pdf text $doc $p [dict get $F serif] 10 72 $y $m
    rightText $doc $p [dict get $F serif] 10 250 $y $jobs
    rightText $doc $p [dict get $F serif] 10 380 $y $med
    rightText $doc $p [dict get $F serif] 10 523 $y $fail
    set y [expr {$y - 18}]
}

# The chart: jobs for each month, with axis lines and labels.
set base [expr {$y - 200}]
set h 160
set max 3000
ztcl::pdf line $doc $p $left $base [expr {$left + $width}] $base -width 0.8
foreach tick {0 1000 2000 3000} {
    set ty [expr {$base + $h * $tick / double($max)}]
    ztcl::pdf line $doc $p $left $ty [expr {$left + $width}] $ty -width 0.3 -color {0.85 0.85 0.85}
    rightText $doc $p [dict get $F sans] 8 [expr {$left - 6}] [expr {$ty - 3}] $tick -color {0.45 0.45 0.45}
}
set i 0
foreach {m jobs med fail} $data {
    set bx [expr {$left + 40 + $i * 140}]
    set bh [expr {$h * $jobs / double($max)}]
    ztcl::pdf rect $doc $p $bx $base 80 $bh -fill {0.2 0.38 0.62}
    set lw [ztcl::pdf measure $doc [dict get $F sans] 9 $m]
    ztcl::pdf text $doc $p [dict get $F sans] 9 [expr {$bx + 40 - $lw / 2}] [expr {$base - 14}] $m
    incr i
}
ztcl::pdf text $doc $p [dict get $F sansbold] 9 $left [expr {$base + $h + 14}] "Jobs for each month"
save $doc $out
