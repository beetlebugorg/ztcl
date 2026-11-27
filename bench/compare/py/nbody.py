# Micro benchmark: the n-body simulation of the Computer Language
# Benchmarks Game, for N steps.
import sys
from math import sqrt
PI = 3.141592653589793
SOLAR_MASS = 4 * PI * PI
DAYS = 365.24
bodies = [
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS],
    [4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
     1.66007664274403694e-03 * DAYS, 7.69901118419740425e-03 * DAYS, -6.90460016972063023e-05 * DAYS,
     9.54791938424326609e-04 * SOLAR_MASS],
    [8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
     -2.76742510726862411e-03 * DAYS, 4.99852801234917238e-03 * DAYS, 2.30417297573763929e-05 * DAYS,
     2.85885980666130812e-04 * SOLAR_MASS],
    [1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
     2.96460137564761618e-03 * DAYS, 2.37847173959480950e-03 * DAYS, -2.96589568540237556e-05 * DAYS,
     4.36624404335156298e-05 * SOLAR_MASS],
    [1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
     2.68067772490389322e-03 * DAYS, 1.62824170038242295e-03 * DAYS, -9.51592254519715870e-05 * DAYS,
     5.15138902046611451e-05 * SOLAR_MASS],
]
pairs = [(bodies[i], bodies[j]) for i in range(5) for j in range(i + 1, 5)]

def energy():
    e = 0.0
    for i, (x, y, z, vx, vy, vz, m) in enumerate(bodies):
        e += 0.5 * m * (vx * vx + vy * vy + vz * vz)
        for b in bodies[i + 1:]:
            dx, dy, dz = x - b[0], y - b[1], z - b[2]
            e -= m * b[6] / sqrt(dx * dx + dy * dy + dz * dz)
    return e

def advance(dt, n):
    for _ in range(n):
        for b1, b2 in pairs:
            dx, dy, dz = b1[0] - b2[0], b1[1] - b2[1], b1[2] - b2[2]
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * sqrt(d2))
            m1, m2 = b1[6], b2[6]
            b1[3] -= dx * m2 * mag; b1[4] -= dy * m2 * mag; b1[5] -= dz * m2 * mag
            b2[3] += dx * m1 * mag; b2[4] += dy * m1 * mag; b2[5] += dz * m1 * mag
        for b in bodies:
            b[0] += dt * b[3]; b[1] += dt * b[4]; b[2] += dt * b[5]

px = py = pz = 0.0
for b in bodies:
    px += b[3] * b[6]; py += b[4] * b[6]; pz += b[5] * b[6]
bodies[0][3], bodies[0][4], bodies[0][5] = -px / SOLAR_MASS, -py / SOLAR_MASS, -pz / SOLAR_MASS
print("%.9f" % energy())
advance(0.01, int(sys.argv[1]))
print("%.9f" % energy())
