# The same paragraph broken with first fit and with total fit, with and
# without hyphens, as one PDF page (for the guide "Typesetting in Tcl").
#   ztcl --allow channels,file --tclsh examples/typeset/compare.tcl compare.pdf
source [file join [file dirname [info script]] .. pdf common.tcl]
set out [expr {$argc > 0 ? [lindex $argv 0] : "compare.pdf"}]
set fontfile [file join [file dirname [info script]] .. .. book fonts SourceSerif4-Regular.ttf]
set doc [ztcl::pdf create]
set F [loadFonts $doc]
set tf [ztcl::typeset font load [slurp $fontfile]]
set text "In olden times when wishing still helped one, there lived a king whose daughters were all beautiful; and the youngest was so beautiful that the sun itself, which has seen so much, was astonished whenever it shone in her face. Close by the king's castle lay a great dark forest, and under an old lime-tree in the forest was a well."
set p [ztcl::pdf page $doc 612 440]
set width 240
set cells {
    {greedy 0 "First fit, no hyphens"} {total 0 "Total fit, no hyphens"}
    {greedy 1 "First fit, hyphens"} {total 1 "Total fit, hyphens"}
}
foreach cell $cells i {0 1 2 3} {
    lassign $cell method hyph label
    set x0 [expr {48 + ($i % 2) * 276}]
    set y [expr {400 - ($i / 2) * 200}]
    ztcl::pdf text $doc $p [dict get $F sansbold] 9 $x0 $y $label -color {0.3 0.3 0.3}
    set y [expr {$y - 18}]
    foreach line [ztcl::typeset break $text -width $width -font $tf -size 10 -method $method -hyphenate $hyph] {
        foreach {x word} [dict get $line words] {
            ztcl::pdf text $doc $p [dict get $F serif] 10 [expr {$x0 + $x}] $y $word
        }
        # A mark of a loose line: the spaces stretch more than their limit.
        if {[dict get $line ratio] > 1} {
            ztcl::pdf rect $doc $p [expr {$x0 + $width + 4}] [expr {$y + 1}] 3 6 -fill {0.85 0.3 0.2}
        }
        set y [expr {$y - 13}]
    }
}
save $doc $out
