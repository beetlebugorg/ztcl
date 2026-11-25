# Integer results that are zero. Tcl gives the integer 0, which is +0
# in an output column, and the vector program adds +0.0 to each integer
# result that can be -0.
point proc int_zero {x y} {
    set k [expr {int(fmod($x, 1e6)) * 0 * -1}]
    speed [expr {-$k}]
    flow [expr {(int(fmod($y, 1e6)) * 0) / -2}]
    width [expr {round(-0.25) + int(-0.5)}]
    skip
}
