# The checks of the hash table and assoc data slots: tests/cext/cxhash.c.
puts [catch {load $dir/cxhash.so} msg]:$msg
foreach g {strings words objs custom assoc lookup} {
    puts "$g [catch {cxhash $g} msg]:$msg"
}
puts [catch {cxhash nosuch} msg]:$msg
