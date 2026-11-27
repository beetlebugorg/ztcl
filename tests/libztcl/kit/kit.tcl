# The script of tools/libztcl/kit.sh. The caller sets dir to the folder
# of the extension kitext.
lappend auto_path $dir
puts [package require kitext]
puts [package vsatisfies $kitext_stubs 8.6]
puts [kitext_sum 1 2 3 40]
puts [kitext_join a {b c} d]
puts [catch {kitext_sum 1 x} msg]
puts $msg
puts [llength [info commands kitext_*]]
