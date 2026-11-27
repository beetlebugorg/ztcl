# Justified text in a terminal, 48 columns wide.
package require ztcl::typeset
set text {ztcl::typeset breaks a paragraph into lines with the total-fit algorithm of Knuth and Plass. It looks at the whole paragraph, so the spaces stay even from line to line.

The same command works on a grid of characters, for a terminal or a README, and with a font, for a PDF or a canvas.}
puts [ztcl::typeset justify $text -width 48]
