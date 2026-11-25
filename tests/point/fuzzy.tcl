# The fuzzy skin proc of the point tests in src/point.zig.
point proc fuzzy {x y z feature} {
    if {$feature ne "outer_wall"} { return }
    set n [noise3 $x $y [expr {$z * 4}]]
    offset [expr {$n * 0.3}]
}
