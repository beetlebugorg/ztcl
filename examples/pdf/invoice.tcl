# A one-page invoice: a header, the addresses, a table of items with
# totals, and a note.
source [file join [file dirname [info script]] common.tcl]
set out [expr {$argc > 0 ? [lindex $argv 0] : "invoice.pdf"}]

set doc [ztcl::pdf create]
set F [loadFonts $doc]
ztcl::pdf info $doc Title "Invoice 2026-0042"
set p [ztcl::pdf page $doc 612 792]
set gray {0.45 0.45 0.45}
set accent {0.12 0.25 0.45}

ztcl::pdf rect $doc $p 0 742 612 50 -fill $accent
ztcl::pdf text $doc $p [dict get $F sansbold] 22 54 760 "INVOICE" -color {1 1 1}
rightText $doc $p [dict get $F sans] 10 558 764 "No. 2026-0042  ·  27 November 2026" -color {1 1 1}

set y 700
foreach {label lines} {
    "From" {"Example Tools LLC" "100 Harbor Road" "Portland, ME 04101"}
    "Bill to" {"Northwind Print Co." "22 Mill Street" "Burlington, VT 05401"}
} {
    set x [expr {$label eq "From" ? 54 : 320}]
    ztcl::pdf text $doc $p [dict get $F sansbold] 8 $x $y [string toupper $label] -color $gray
    set yy [expr {$y - 16}]
    foreach l $lines {
        ztcl::pdf text $doc $p [dict get $F serif] 10.5 $x $yy $l
        set yy [expr {$yy - 14}]
    }
}

# The table.
set items {
    "Typesetting engine license, one year" 1 1200.00
    "Font subsetting support" 3 85.00
    "Training, half a day" 2 450.00
    "Printed manuals" 25 12.50
}
set cols {54 360 430 558}
set y 600
ztcl::pdf rect $doc $p 54 [expr {$y - 6}] 504 20 -fill {0.93 0.94 0.96}
ztcl::pdf text $doc $p [dict get $F sansbold] 9 60 $y "Item"
rightText $doc $p [dict get $F sansbold] 9 410 $y "Qty"
rightText $doc $p [dict get $F sansbold] 9 490 $y "Price"
rightText $doc $p [dict get $F sansbold] 9 552 $y "Amount"
set total 0
set y [expr {$y - 24}]
foreach {name qty price} $items {
    set amount [expr {$qty * $price}]
    set total [expr {$total + $amount}]
    ztcl::pdf text $doc $p [dict get $F serif] 10 60 $y $name
    rightText $doc $p [dict get $F serif] 10 410 $y $qty
    rightText $doc $p [dict get $F serif] 10 490 $y [format %.2f $price]
    rightText $doc $p [dict get $F serif] 10 552 $y [format %.2f $amount]
    ztcl::pdf line $doc $p 54 [expr {$y - 7}] 558 [expr {$y - 7}] -width 0.4 -color {0.8 0.8 0.8}
    set y [expr {$y - 22}]
}
set tax [expr {$total * 0.055}]
foreach {label value font} [list Subtotal $total serif "Tax (5.5%)" $tax serif Total [expr {$total + $tax}] sansbold] {
    rightText $doc $p [dict get $F $font] 10.5 490 $y $label
    rightText $doc $p [dict get $F $font] 10.5 552 $y "\$[format %.2f $value]"
    set y [expr {$y - 18}]
}

# A justified note at the bottom, from ztcl::typeset.
set note "Payment is due within 30 days. Pay by bank transfer to the account on the back of this page, and give the invoice number as the reference. Thank you for your order."
set y 150
ztcl::pdf text $doc $p [dict get $F sansbold] 8 54 [expr {$y + 18}] "NOTES" -color $gray
set tf [ztcl::typeset font load [slurp [file join [file dirname [info script]] .. .. book fonts SourceSerif4-Regular.ttf]]]
foreach line [ztcl::typeset break $note -width 300 -font $tf -size 9.5] {
    foreach {x word} [dict get $line words] {
        ztcl::pdf text $doc $p [dict get $F serif] 9.5 [expr {54 + $x}] $y $word -color {0.2 0.2 0.2}
    }
    set y [expr {$y - 13}]
}
save $doc $out
