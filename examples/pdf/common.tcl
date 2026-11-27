# Helpers of the PDF examples: read a file, load the fonts of the book,
# and write the document. Run each example from the top folder of ztcl:
#   ztcl --allow channels,file --tclsh examples/pdf/invoice.tcl invoice.pdf
package require ztcl::pdf
package require ztcl::typeset

proc slurp {path} {
    set f [open $path rb]
    set data [read $f]
    close $f
    return $data
}

# Adds the fonts of book/fonts to `doc` and gives a dict: face -> number.
proc loadFonts {doc} {
    set dir [file join [file dirname [info script]] .. .. book fonts]
    set fonts {}
    foreach {key file} {
        serif SourceSerif4-Regular.ttf italic SourceSerif4-Italic.ttf
        bold SourceSerif4-Semibold.ttf sans SourceSans3-Regular.ttf
        sansbold SourceSans3-Semibold.ttf mono SourceCodePro-Regular.ttf
    } {
        dict set fonts $key [ztcl::pdf font $doc [slurp [file join $dir $file]]]
    }
    return $fonts
}

proc save {doc path} {
    set f [open $path wb]
    puts -nonewline $f [ztcl::pdf bytes $doc]
    close $f
    puts "wrote $path, [ztcl::pdf pages $doc] pages"
}

# Shows `text` with its right end at x.
proc rightText {doc page font size x y text args} {
    set w [ztcl::pdf measure $doc $font $size $text]
    ztcl::pdf text $doc $page $font $size [expr {$x - $w}] $y $text {*}$args
}
