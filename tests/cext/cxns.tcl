# The checks of the area namespaces: tests/cext/cxns.c.
load $dir/cxns.so
proc try {script} {
    set rc [catch {uplevel 1 $script} msg]
    puts "  $rc: $msg"
}

puts namespaces
try {cxns create ::n1}
try {cxns create ::n1::n2}
try {cxns create ::n1}
puts [namespace exists ::n1::n2]
try {cxns find n1}
try {cxns find n2 ::n1}
try {cxns find ::nosuch}
try {cxns find n2 ::n1 global}
try {cxns current}
try {namespace eval ::n1 {cxns current}}
proc ::n1::p {} {}
proc ::n1::q {} {}
try {cxns export ::n1 p keep}
try {cxns export ::n1 q keep}
try {cxns export ::n1 q reset}
try {cxns export ::n1 p keep}
namespace eval ::n3 {}
try {cxns import ::n3 ::n1::* keep}
puts [lsort [info commands ::n3::*]]
proc ::n3::p {} {}
try {cxns import ::n3 ::n1::p keep}
try {cxns import ::n3 ::n1::p force}
try {cxns forget ::n3 ::n1::q}
puts [lsort [info commands ::n3::*]]
try {cxns unknown ::n1}
try {cxns unknown ::n1 {myunknown x}}
try {cxns unknown ::n1}
cxns delete ::n1
puts [namespace exists ::n1]
puts [cxns log]

puts ensembles
namespace eval ::e { proc one {args} {return "one $args"}; proc two {} {return two}; namespace export * }
try {cxns ensemble ens ::e}
try {cxns ensemble ::top -}
try {cxns isens ::e::ens}
try {cxns isens set}
try {cxns isens nosuch}
try {cxns ensget ::e::ens}
try {::e::ens one 1}
try {::e::ens tw}
try {cxns ensset ::e::ens map {go ::e::one}}
try {::e::ens go 2}
try {cxns ensset ::e::ens subcommands {go}}
try {cxns ensset ::e::ens flags 0}
try {cxns ensset ::e::ens parameters {p}}
try {cxns ensset ::e::ens unknown {apply {args {}}}}
try {cxns ensget ::e::ens}
try {::e::ens x go}
try {cxns notens set}
