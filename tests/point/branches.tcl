# The proc with branches of the point tests in src/point.zig.
point proc p {x y z width feature} {
    set k 2
    if {$feature eq "infill"} {
        skip
        return
    } elseif {$feature == "skin" && $z > 0.5} {
        set k [expr {$k + 7 / 2}]
        flow [expr {1.0 + 0.1 * sin($x)}]
    } else {
        if {$x > 100} { set k [expr {$k * 3}] }
        width [expr {$width * ($y > 100 ? 1.1 : 0.9)}]
    }
    move [expr {0.01 * $k}] [expr {clamp(noise3($x, $y, $z), -0.5, 0.5)}]
    if {$k % 2 == 0} { return }
    speed [expr {max(10, min(60, hypot($x - 100, $y - 100)))}]
}
