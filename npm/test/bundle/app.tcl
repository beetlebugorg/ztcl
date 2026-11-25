# Reads an embedded file. The bundle needs the file capability.
set f [open data/greeting.txt]
set g [gets $f]
close $f
puts "$g [sq 7]"
