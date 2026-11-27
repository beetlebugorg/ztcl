# Micro benchmark: the n-body simulation of the Computer Language
# Benchmarks Game, for N steps.
set PI 3.141592653589793
set SOLAR_MASS [expr {4 * $PI * $PI}]
set DAYS 365.24
# x y z vx vy vz mass
set bodies [list \
    [list 0.0 0.0 0.0 0.0 0.0 0.0 $SOLAR_MASS] \
    [list 4.84143144246472090e+00 -1.16032004402742839e+00 -1.03622044471123109e-01 \
        [expr {1.66007664274403694e-03 * $DAYS}] [expr {7.69901118419740425e-03 * $DAYS}] \
        [expr {-6.90460016972063023e-05 * $DAYS}] [expr {9.54791938424326609e-04 * $SOLAR_MASS}]] \
    [list 8.34336671824457987e+00 4.12479856412430479e+00 -4.03523417114321381e-01 \
        [expr {-2.76742510726862411e-03 * $DAYS}] [expr {4.99852801234917238e-03 * $DAYS}] \
        [expr {2.30417297573763929e-05 * $DAYS}] [expr {2.85885980666130812e-04 * $SOLAR_MASS}]] \
    [list 1.28943695621391310e+01 -1.51111514016986312e+01 -2.23307578892655734e-01 \
        [expr {2.96460137564761618e-03 * $DAYS}] [expr {2.37847173959480950e-03 * $DAYS}] \
        [expr {-2.96589568540237556e-05 * $DAYS}] [expr {4.36624404335156298e-05 * $SOLAR_MASS}]] \
    [list 1.53796971148509165e+01 -2.59193146099879641e+01 1.79258772950371181e-01 \
        [expr {2.68067772490389322e-03 * $DAYS}] [expr {1.62824170038242295e-03 * $DAYS}] \
        [expr {-9.51592254519715870e-05 * $DAYS}] [expr {5.15138902046611451e-05 * $SOLAR_MASS}]]]

proc offset {bodiesVar} {
    upvar 1 $bodiesVar bodies
    global SOLAR_MASS
    set px 0.0; set py 0.0; set pz 0.0
    foreach b $bodies {
        lassign $b x y z vx vy vz m
        set px [expr {$px + $vx * $m}]
        set py [expr {$py + $vy * $m}]
        set pz [expr {$pz + $vz * $m}]
    }
    lset bodies 0 3 [expr {-$px / $SOLAR_MASS}]
    lset bodies 0 4 [expr {-$py / $SOLAR_MASS}]
    lset bodies 0 5 [expr {-$pz / $SOLAR_MASS}]
}

proc energy {bodies} {
    set e 0.0
    set n [llength $bodies]
    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $bodies $i] x y z vx vy vz m
        set e [expr {$e + 0.5 * $m * ($vx * $vx + $vy * $vy + $vz * $vz)}]
        for {set j [expr {$i + 1}]} {$j < $n} {incr j} {
            lassign [lindex $bodies $j] x2 y2 z2 - - - m2
            set dx [expr {$x - $x2}]; set dy [expr {$y - $y2}]; set dz [expr {$z - $z2}]
            set e [expr {$e - $m * $m2 / sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
        }
    }
    return $e
}

proc advance {bodiesVar dt} {
    upvar 1 $bodiesVar bodies
    set n [llength $bodies]
    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $bodies $i] x y z vx vy vz m
        for {set j [expr {$i + 1}]} {$j < $n} {incr j} {
            lassign [lindex $bodies $j] x2 y2 z2 vx2 vy2 vz2 m2
            set dx [expr {$x - $x2}]; set dy [expr {$y - $y2}]; set dz [expr {$z - $z2}]
            set d2 [expr {$dx * $dx + $dy * $dy + $dz * $dz}]
            set mag [expr {$dt / ($d2 * sqrt($d2))}]
            set vx [expr {$vx - $dx * $m2 * $mag}]
            set vy [expr {$vy - $dy * $m2 * $mag}]
            set vz [expr {$vz - $dz * $m2 * $mag}]
            lset bodies $j 3 [expr {$vx2 + $dx * $m * $mag}]
            lset bodies $j 4 [expr {$vy2 + $dy * $m * $mag}]
            lset bodies $j 5 [expr {$vz2 + $dz * $m * $mag}]
        }
        lset bodies $i [list [expr {$x + $dt * $vx}] [expr {$y + $dt * $vy}] [expr {$z + $dt * $vz}] $vx $vy $vz $m]
    }
}

offset bodies
puts [format %.9f [energy $bodies]]
set steps [lindex $argv 0]
for {set k 0} {$k < $steps} {incr k} { advance bodies 0.01 }
puts [format %.9f [energy $bodies]]
