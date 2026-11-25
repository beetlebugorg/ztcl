# A proc that uses each operation of the point subset once. The
# arguments of int(), round(), entier(), and wide() stay small with
# fmod, because Tcl gives an integer of 64 bits and the vector program
# keeps a double for a larger value.
point proc ops {x y z width height speed flow layer path dist feature} {
    set a [expr {$x + $y - $z * $width / ($height + 1)}]
    set i [expr {int(fmod($x, 1e6)) / 3 + int(fmod($y, 1e6)) % 5 - -int(fmod($z, 1e6))}]
    set c [expr {$x < $y || ($z >= $width && !($height == $speed)) || $flow <= $layer || $path > $dist || $path != $x}]
    set f [expr {abs($a) + sqrt(abs($y)) + floor($z) + ceil($width) + round(fmod($height, 1e6)) + double($speed) + entier(fmod($flow, 1e6)) + wide(fmod($layer, 1e6))}]
    set t [expr {acos(fmod($x, 1)) + asin(fmod($y, 1)) + atan($z) + cos($x) + cosh(fmod($y, 3)) + exp(fmod($z, 5)) + log(abs($x) + 1) + log10(abs($y) + 1) + sin($z) + sinh(fmod($x, 3)) + tan($y) + tanh($z)}]
    set u [expr {atan2($x, $y) + fmod($z, 0.7) + hypot($x, $z) + pow(abs($y), 0.5) + min($x, $y, $z) + max($x, $y) + noise2($x, $y)}]
    set v [expr {clamp($a, -1, 1) + lerp($x, $y, 0.25) + noise3($x, $y, $z) + bool($c) + ($c ? 1.5 : -2.5)}]
    if {$feature eq "skin" || $feature == "support"} {
        offset [expr {$v * 0.1}]
        if {$x > 0} { return }
        flow [expr {$t + $u}]
    } elseif {$c} {
        width [expr {$f + $i}]
        set n [noise3 $z $y $x]
        speed [expr {$n * 10 + pow(2, 3)}]
    } else {
        skip
    }
    move [expr {$a * 0.01}] [expr {$u * 0.01}]
}
