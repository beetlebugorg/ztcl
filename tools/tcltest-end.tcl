# SPDX-License-Identifier: BSD-2-Clause
# Runs after a test file. Prints the reason for each skipped test and
# the counts, also for a file that stops before its cleanupTests.
foreach why [lsort [array names tt_why]] {
    puts "skipped\t$why\t$tt_why($why)"
}
puts "pass $tt_pass fail $tt_fail skip $tt_skip"
