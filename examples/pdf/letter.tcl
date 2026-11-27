# A letter in one embedded font family, with justified, hyphenated
# paragraphs from ztcl::typeset.
source [file join [file dirname [info script]] common.tcl]
set out [expr {$argc > 0 ? [lindex $argv 0] : "letter.pdf"}]

set doc [ztcl::pdf create]
set F [loadFonts $doc]
set tf [ztcl::typeset font load [slurp [file join [file dirname [info script]] .. .. book fonts SourceSerif4-Regular.ttf]]]
set p [ztcl::pdf page $doc 612 792]
set left 90
set width 432
set size 11
set lead 15

ztcl::pdf text $doc $p [dict get $F sansbold] 12 $left 712 "Example Tools LLC"
ztcl::pdf text $doc $p [dict get $F sans] 9 $left 698 "100 Harbor Road · Portland, ME 04101" -color {0.45 0.45 0.45}
rightText $doc $p [dict get $F serif] $size [expr {$left + $width}] 650 "27 November 2026"
set y 610
foreach l {"Ms. Ada Byron" "Northwind Print Co." "22 Mill Street" "Burlington, VT 05401"} {
    ztcl::pdf text $doc $p [dict get $F serif] $size $left $y $l
    set y [expr {$y - $lead}]
}
set y [expr {$y - $lead}]
ztcl::pdf text $doc $p [dict get $F serif] $size $left $y "Dear Ms. Byron,"
set y [expr {$y - 1.5 * $lead}]
set paras {
    "Thank you for your letter of 12 November and for the sample pages of the new catalog. The typography of the proofs is excellent, and the paragraphs keep an even color from the first page to the last."
    "We checked each page of the proof against the original files. The hyphenation follows the American patterns, the fonts are embedded as subsets, and each link of the table of contents goes to the right page. We found two small problems in the price list, and the enclosed sheet marks them."
    "We can print the full run in the first week of December. Please send the final files before the end of this month."
}
foreach para $paras {
    foreach line [ztcl::typeset break $para -width $width -font $tf -size $size] {
        foreach {x word} [dict get $line words] {
            ztcl::pdf text $doc $p [dict get $F serif] $size [expr {$left + $x}] $y $word
        }
        set y [expr {$y - $lead}]
    }
    set y [expr {$y - $lead / 2.0}]
}
set y [expr {$y - $lead}]
ztcl::pdf text $doc $p [dict get $F serif] $size $left $y "Sincerely,"
ztcl::pdf text $doc $p [dict get $F italic] $size $left [expr {$y - 3 * $lead}] "Jordan Lee, Production"
save $doc $out
