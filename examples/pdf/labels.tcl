# A sheet of address labels: 3 columns by 10 rows on US Letter, the
# layout of the common 1 by 2-5/8 inch labels.
source [file join [file dirname [info script]] common.tcl]
set out [expr {$argc > 0 ? [lindex $argv 0] : "labels.pdf"}]

set doc [ztcl::pdf create]
set F [loadFonts $doc]
set p [ztcl::pdf page $doc 612 792]
set names {
    "Ada Byron" "Northwind Print Co." "22 Mill Street" "Burlington, VT 05401"
}
set w 189; set h 72; set gap 9; set left 13.5; set top 756
for {set row 0} {$row < 10} {incr row} {
    for {set col 0} {$col < 3} {incr col} {
        set x [expr {$left + $col * ($w + $gap)}]
        set y [expr {$top - $row * $h}]
        # A thin guide of the label edge, to check the alignment on a test print.
        ztcl::pdf rect $doc $p $x [expr {$y - $h}] $w 0.3 -fill {0.85 0.85 0.85}
        set ly [expr {$y - 20}]
        set n [expr {$row * 3 + $col + 1}]
        ztcl::pdf text $doc $p [dict get $F sansbold] 10 [expr {$x + 12}] $ly "[lindex $names 0] ($n)"
        foreach l [lrange $names 1 end] {
            set ly [expr {$ly - 12}]
            ztcl::pdf text $doc $p [dict get $F serif] 9.5 [expr {$x + 12}] $ly $l
        }
    }
}
save $doc $out
