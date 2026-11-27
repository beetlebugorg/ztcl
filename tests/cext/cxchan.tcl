# The checks of the channel slots from C: tests/cext/cxchan.c. The
# script uses no channel command, so the WebAssembly path runs it too.
proc try {args} {
    set code [catch {uplevel 1 $args} msg]
    puts "[lrange $args 0 1] $code:$msg"
}
puts [catch {load $dir/cxchan.so} msg]:$msg
set m [cxchan open]
try cxchan info $m
try cxchan cfg $m
try cxchan cfg $m -translation
try cxchan cfg $m -size
try cxchan cfg $m -nosuch
try cxchan cfg $m -empty 0
try cxchan write $m "one\ntwo\r\nthree\rfour"
try cxchan info $m
try cxchan raw $m
try cxchan flush $m
try cxchan info $m
try cxchan raw $m
try cxchan tell $m
try cxchan seek $m 0
try cxchan gets $m
try cxchan info $m
try cxchan gets $m
try cxchan getsobj $m
try cxchan tell $m
try cxchan read $m
try cxchan eof $m
try cxchan gets $m
try cxchan seek $m 4
try cxchan eof $m
try cxchan read $m 3
try cxchan cfg $m -translation binary
try cxchan read $m
try cxchan seek $m 0
try cxchan cfg $m -translation lf
try cxchan read $m
try cxchan seek $m 0
try cxchan cfg $m -translation cr
try cxchan read $m
try cxchan seek $m 0
try cxchan cfg $m -translation crlf
try cxchan read $m
try cxchan seek $m 0 end
try cxchan cfg $m -translation {auto crlf}
try cxchan cfg $m -translation
try cxchan write $m "\nfive\n"
try cxchan cfg $m -translation {auto lf}
try cxchan flush $m
try cxchan raw $m
# Encodings.
try cxchan seek $m 0 end
try cxchan cfg $m -encoding utf-8
try cxchan write $m "é中"
try cxchan cfg $m -encoding iso8859-1
try cxchan write $m "é中"
try cxchan cfg $m -encoding binary
try cxchan cfg $m -translation
try cxchan wbytes $m "\x01\xff"
try cxchan cfg $m -translation auto
try cxchan cfg $m -encoding utf-8
try cxchan flush $m
try cxchan tell $m
try cxchan seek $m -11 end
try cxchan read $m
try cxchan seek $m -11 end
try cxchan rbytes $m 20
try cxchan seek $m -11 end
try cxchan cfg $m -encoding iso8859-1
try cxchan read $m
try cxchan cfg $m -encoding nosuch
try cxchan cfg $m -encoding utf-8
# Buffering.
try cxchan cfg $m -buffering line
try cxchan cfg $m -buffering
try cxchan seek $m 0 end
try cxchan write $m "a"
try cxchan info $m
try cxchan write $m "b\nc"
try cxchan info $m
try cxchan cfg $m -buffering none
try cxchan write $m "d"
try cxchan info $m
try cxchan cfg $m -buffering full
try cxchan cfg $m -buffersize 10
try cxchan info $m
try cxchan cfg $m -buffering bad
try cxchan cfg $m -blocking 0
try cxchan cfg $m -blocking
try cxchan cfg $m -blocking 1
try cxchan cfg $m -eofchar x
try cxchan cfg $m -eofchar
try cxchan seek $m 0
try cxchan read $m
try cxchan eof $m
try cxchan cfg $m -eofchar {}
# Input that blocks.
try cxchan cfg $m -empty 1
try cxchan seek $m 0 end
try cxchan write $m "\npart"
try cxchan flush $m
try cxchan seek $m -5 end
try cxchan gets $m
try cxchan gets $m
try cxchan blocked $m
try cxchan read $m
try cxchan cfg $m -empty 0
try cxchan gets $m
# Ungets.
try cxchan seek $m 0
try cxchan ungets $m "back\n"
try cxchan gets $m
try cxchan gets $m
try cxchan ungets $m "tail\n" end
try cxchan read $m 10
# A transform.
set n [cxchan open]
try cxchan push $n
try cxchan info $n
try cxchan write $n "Hello, World\nline 2\n"
try cxchan flush $n
try cxchan raw $n
try cxchan seek $n 0
try cxchan pop $n
try cxchan info $n
try cxchan seek $n 0
try cxchan read $n
try cxchan seek $n 0
try cxchan push $n
try cxchan gets $n
try cxchan read $n
try cxchan same $n $n
try cxchan closed
try cxchan close $n
try cxchan closed
try cxchan info $n
# Events.
try cxchan events $m
try cxchan error $m
try cxchan names
try cxchan std
try cxchan close $m
try cxchan closed
try cxchan names
set r [cxchan open r]
try cxchan info $r
try cxchan cfg $r
try cxchan write $r x
try cxchan close $r
try cxchan info nosuch
