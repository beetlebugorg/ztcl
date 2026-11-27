# The checks of threads, mutexes, conditions, thread data, the time, and
# the command info slots: tests/cext/cxthr.c.
namespace eval cxthr {}
puts [catch {load $dir/cxthr.so} msg]:$msg
puts [cxthr::data]:[cxthr::data]:[cxthr::data]
puts [cxthr::run 4]
puts [cxthr::run 1]
puts [cxthr::wait 30]
puts [cxthr::dash a b c]
puts [cxthr::dash]
puts [cxthr::info cxthr::dash]
puts [cxthr::info cxthr::data]
puts [cxthr::info list]
puts [cxthr::info nosuch]
puts [cxthr::retarget]:[cxthr::dash x y]
puts [cxthr::name]
puts [cxthr::wrap set]
proc set args { return "new set: $args" }
puts [set a 1]
puts [cxthr::orig cxv 5]:$cxv
rename set {}
puts [cxthr::orig cxv]
