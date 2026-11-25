# A noise in the condition of an elseif. The fuzzer found that the
# condition used the mask of the body before it, so Program.run gave
# another value than runSlow when few points took that body.
point proc elseif_noise {x y} {
    if {$x > 135} {
        skip
    } elseif {noise3($x, $y, 0.5) > 0} {
        offset 1
    }
}
