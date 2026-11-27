# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the lazy DFA of a pattern stays with the pattern,
# and it runs the asserts of the start and the end of the text. Each
# search gives the match and the count of compute units of the thread
# simulation.
set line {10.0.12.200 - - [26/Nov/2026:10:00:00 +0000] "GET /api/v1/users HTTP/1.1" 200 4312}
set pats {
    {^\S+ \S+ \S+ \[[^\]]+\] "\S+ \S+ [^"]*" \d+ \d+}
    {^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+)}
    {(\d+) (\d+)$} {\d+$} {^\d+} {^10\.} {users$} {^.*$} {^(\w+)=(.*)$}
    {\A10} {4312\Z} {"(\S+) (\S+)} {l+} {a*} {^} {$} {x*$} {^$} {o[^ ]*s}
}
set texts [list $line "key7=value of 7" "" "abc\ndef" "héllo wörld 12 34" "12 34" "x" [string repeat "ab 12 " 8]]
proc run {pats texts} {
    set r {}
    foreach round {1 2} {
        foreach p $pats {
            foreach t $texts {
                lappend r [regexp -inline -indices -- $p $t] [regexp -all -- $p $t]
                lappend r [regexp -line -all -inline -- $p $t] [regexp -nocase -start [expr {min(2, [string length $t])}] -- $p $t]
                lappend r [regsub -all -- $p $t <&>]
            }
        }
    }
    return $r
}
puts [join [run $pats $texts] \n]
