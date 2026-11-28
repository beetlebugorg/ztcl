# ztcl::fhe: the prototype and its measurements

`ztcl::fhe` is a prototype of fully homomorphic encryption in ztcl. It is new Zig code from the published papers, with no dependency. It is in a build only with `-Dmod-fhe=true`. [The module page](../modules/fhe.md) has the commands, and [References](../references/fhe.md) has each source.

The prototype is not ready for real data. The code is not constant time, the samplers use floating-point numbers, secret data stays in freed memory, and no person reviewed the code or the parameters.

## The parts

| File | Contents |
|---|---|
| `src/fhe/ntt.zig` | Arithmetic modulo a prime below 2^61 (Barrett for a 128-bit product, Shoup for a product with a constant), the search for NTT primes, and the negacyclic transform: scalar code and code with vectors of four 64-bit words. |
| `src/fhe/ckks.zig` | CKKS in RNS form: the context and its primes, the encoder, the key generation, encrypt, decrypt, add, multiply with relinearization, rescale, rotation with Galois keys, plain factors and terms, the level change, the slot sum, and the dot product. |
| `src/fhe/tfhe.zig` | TFHE: the keys, the gate bootstrap, the programmable bootstrap with a table, the key switch, and six gates. |
| `src/fhe/fhe.zig` | The root of the library, and the logistic regression score. |
| `src/fhe/cmd.zig` | The command `ztcl::fhe`. |
| `src/fhe/ntt_fuzz.zig` | The fuzzer of the arithmetic and the transform. |
| `src/fhe/bench.zig` | The measurements of this page. |

The library imports no file of the interpreter. Its tests, its fuzzer, and its measurements are builds of a few seconds.

| Command | What it does |
|---|---|
| `zig build fhe-test` | Runs the tests of the library with small rings. |
| `zig build fhe-test -Doptimize=ReleaseSafe` | Runs the TFHE gates with the 128-bit parameters too. |
| `zig build fhe-ntt-fuzz -- --seconds N --seed N` | Runs the fuzzer. |
| `zig build fhe-bench -Doptimize=ReleaseFast -- [part ...]` | Prints the times. The parts are `ntt`, `ckks13`, `ckks14`, `ckks15`, `ckks16`, `tfhe`, `dot`, and `logreg`. |
| `zig build -Dmod-fhe=true`, then `ztcl tests/fhe/api.tcl` | Tests the Tcl commands: 31 checks. |

## What is not in the prototype

- CKKS bootstrapping. A ciphertext has the levels of its context and no more.
- Hybrid key switching with several special primes. The key switch has one digit for each prime, so a switch key has (L + 1) * (L + 2) rows and its size grows with the square of the count of primes. This is the reason for the short modulus at n = 2^16.
- AVX-512 IFMA and NEON code. This host has neither. The vector code is generic Zig vector code. It compiles for arm64, but no arm64 measurement exists, so arm64 uses the scalar code.
- Selection of the vector code at run time. The selection is at compile time from the CPU of the target.
- Threads. Each time below is one thread.
- Serialization of keys and ciphertexts, and a split between the secret key and the evaluation keys in the Tcl commands. A key set object has both.
- A pool for the work memory. Each operation allocates its work memory, and for the small operations the page faults of new memory are most of the time (see `add` below).
- The cross builds for macOS and Windows were not run.

## Correctness

Each test compares decrypt(f(encrypt(x))) with f(x).

- CKKS, n = 2^8 in the tests and n = 2^13 to 2^16 in the measurements: add, multiply, multiply before the rescale (a 2^80 scale, so the decoder reads integers above 64 bits), a chain of four squares to level 0, rotations to the left and the right, plain factors and terms, the dot product, and the logistic regression score. The tolerance is 1e-7 for a new ciphertext, 1e-6 after one multiplication, and 1e-5 after a chain or a slot sum. The measured errors are in the tables below.
- TFHE: the truth table of each of the six gates, each followed by a second gate, with a small parameter set and with the 128-bit set. The programmable bootstrap gives each entry of a table of four integers. The measurement ran 1,000 NAND gates with the 128-bit set in five runs, and each result was correct.
- The transform: the value at each place against a direct evaluation of the polynomial, the product against the schoolbook product, and the automorphism table against the automorphism of the coefficients.
- The fuzzer ran 275,680 rounds in 60 seconds (seed 7) with no failure. With a planted error in the carry of the vector high multiplication, it stopped in the first 5 seconds.
- The memory limit and the compute limit stop the commands: with `--mem 67108864` the key generation at n = 2^15 fails with an out-of-memory error, and with `--compute 5000` it fails with `compute limit reached`.

## The parameter sets

CKKS uses a ternary secret and an error with the deviation 3.2. The size of QP is the sum of the nominal sizes of the primes. The limit is the largest modulus of the HomomorphicEncryption.org standard (2018, Table 1) for 128 bits of classical security with a ternary secret. The numbers of the limit are from memory of the standard and need a check against the document.

| n | Primes of Q | Special prime | QP | Limit | Levels | Slots |
|---|---|---|---|---|---|---|
| 2^13 | 60 + 2 x 40 bits | 60 bits | 200 bits | 218 bits | 2 | 4,096 |
| 2^14 | 60 + 6 x 40 bits | 60 bits | 360 bits | 438 bits | 6 | 8,192 |
| 2^15 | 60 + 12 x 40 bits | 60 bits | 600 bits | 881 bits | 12 | 16,384 |
| 2^16 | 60 + 12 x 40 bits | 60 bits | 600 bits | (881 bits at 2^15) | 12 | 32,768 |

The table of the standard stops at n = 2^15. The set of 2^16 has the modulus of the set of 2^15. A larger n with the same modulus is a harder problem, so this set is not weaker than the set of 2^15.

TFHE uses the 128-bit set of the TFHE library: n = 630, N = 1024, k = 1, a bootstrap gadget of 3 digits in base 2^7, a key switch of 8 digits in base 4, and the deviations 2^-15 (LWE) and 2^-25 (bootstrap key). The security estimate is the estimate of the authors of the library. This work did not run a lattice estimator on any set.

## The measurements

The host is an Intel Core i7-6700K (4 cores, 8 threads, AVX2, no AVX-512) with Linux, shared with other work. During the runs the load average was 5 to 9, so two threads often shared one core. Each time is the CPU time of one thread and the least of the repeats in three runs of the program. Single runs differed by up to 1.5 times. The build is `-Doptimize=ReleaseFast` for the CPU of the host, with Zig 0.17.0.

### The transform

One transform of one prime, in microseconds. The size of the prime (50 or 60 bits) made no difference outside the noise. The table has the 50-bit rows.

| n | Forward, scalar | Forward, vector | Inverse, scalar | Inverse, vector |
|---|---|---|---|---|
| 1,024 | 7.88 | 6.65 | 7.51 | 7.17 |
| 2,048 | 16.5 | 13.9 | 16.1 | 15.4 |
| 4,096 | 35.6 | 30.5 | 34.9 | 33.7 |
| 8,192 | 75.2 | 66.4 | 73.2 | 73.3 |
| 16,384 | 159 | 139 | 156 | 153 |
| 32,768 | 342 | 298 | 335 | 330 |
| 65,536 | 724 | 635 | 712 | 710 |

The vector code is 1.13 to 1.19 times as fast forward and 1.00 to 1.05 times as fast for the inverse. The gain is small because AVX2 has no 64-bit high multiplication: the vector code uses four 32-bit multiplications for it. A build for a CPU with AVX2 uses the vector code.

The first scalar code had a branch for each conditional subtraction, and its forward transform was 11.5 microseconds at n = 1,024. The form `min(x, x - m)` with a wrap has no branch, and the time went to 7.2 microseconds.

### CKKS

Times in milliseconds for one operation on new ciphertexts at the top level.

| Operation | n = 2^13 | n = 2^14 | n = 2^15 | n = 2^16 |
|---|---|---|---|---|
| Key generation (secret, public, relinearization, 1 Galois key) | 9.8 | 90.8 | 450 | 962 |
| Encode | 0.53 | 2.67 | 10.4 | 21.1 |
| Encrypt | 1.52 | 6.41 | 23.1 | 48.4 |
| Decrypt and decode | 0.87 | 5.34 | 27.5 | 56.8 |
| Add, in place | 0.028 | 0.19 | 1.02 | 2.52 |
| Add, new ciphertext | 0.17 | 0.86 | 2.69 | 3.59 |
| Multiply + relinearize | 2.96 | 21.1 | 116 | 254 |
| Rescale | 0.57 | 2.68 | 10.3 | 22.3 |
| Rotate | 2.69 | 20.1 | 115 | 248 |
| Encode + multiply by plain + rescale | 1.39 | 6.64 | 27.8 | 54.9 |
| Largest error of x * x in all slots | 2.3e-7 | 5.5e-7 | 1.1e-6 | 2.0e-6 |

Memory:

| Object | n = 2^13 | n = 2^14 | n = 2^15 | n = 2^16 |
|---|---|---|---|---|
| Secret key | 0.25 MB | 1.00 MB | 3.50 MB | 7.00 MB |
| Public key | 0.38 MB | 1.75 MB | 6.50 MB | 13.0 MB |
| Relinearization key | 1.50 MB | 14.0 MB | 91.0 MB | 182 MB |
| Each Galois key | 1.50 MB | 14.0 MB | 91.0 MB | 182 MB |
| Key set with 1 Galois key | 3.66 MB | 30.8 MB | 192 MB | 384 MB |
| Ciphertext at the top level | 0.38 MB | 1.75 MB | 6.50 MB | 13.0 MB |
| Context (tables) | 1.3 MB | 4.5 MB | 15.1 MB | 30.1 MB |
| Peak of the measurement | 7.6 MB | 47.3 MB | 251 MB | 501 MB |

### TFHE

| Measurement | Value |
|---|---|
| NAND gate with the bootstrap and the key switch, least | 51.4 ms |
| NAND gate, mean of 200 gates, in five runs | 53.6 to 87.0 ms |
| Key generation | 402 ms |
| Bootstrap key | 59.1 MB |
| Key-switch key | 59.2 MB |
| Key set (the two keys) | 118.2 MB |
| Ciphertext | 2,524 bytes |

One gate has 630 steps, so a step is 82 microseconds. Each step has 6 forward transforms and 2 inverse transforms of 1,024 places. At the times of the table above, 6.7 and 7.2 microseconds, the transforms are about 55 microseconds of a step.

### End to end

The dot product of 4,096 encrypted values with 4,096 encrypted values, CKKS at n = 2^13:

| Step | Value |
|---|---|
| Key generation with 12 Galois keys | 53.2 ms |
| Encode + encrypt, 2 vectors | 4.5 ms |
| Dot product: 1 multiply, 1 rescale, 12 rotations | 28.3 ms |
| Result | plain -29.107944122, decrypted -29.107946098, error 2.0e-6 |
| Galois keys | 18.0 MB |
| Peak memory | 25.3 MB |

The logistic regression score of 1,024 encrypted features with a plain model, CKKS at n = 2^14. The score is 0.5 + 0.197 y - 0.004 y^3 for y = w.x + b:

| Step | Value |
|---|---|
| Key generation with 10 Galois keys | 337 ms |
| Encode + encrypt | 9.3 ms |
| Score: 1 plain multiply, 10 rotations, 2 multiplies, 2 scalar multiplies | 220 ms |
| Result | y = -1.167508; plain polynomial 0.276366437, decrypted 0.276366568, error 1.3e-7 |
| The logistic function at y | 0.237306 (the polynomial differs by 0.039) |
| Levels used | 3 of 6 |
| Galois keys | 140 MB |
| Peak memory | 180 MB |

## Published numbers of other libraries

No other library was installed, run, or read. Each number below is from a publication, on a different CPU, and in two cases with a different version or a different split of the modulus. Read each ratio as an order of magnitude.

### The transform: Intel HEXL

Boemer and others, "Intel HEXL", Tables 1 and 2: one thread of a Xeon Platinum 8360Y at 2.4 GHz, a 50-bit prime, microseconds.

| n | HEXL native C++ forward | HEXL AVX512-IFMA forward | ztcl forward | HEXL native C++ inverse | HEXL AVX512-IFMA inverse | ztcl inverse |
|---|---|---|---|---|---|---|
| 1,024 | 9.08 | 1.25 | 6.65 | 8.25 | 1.23 | 7.17 |
| 4,096 | 38.8 | 5.81 | 30.5 | 37.8 | 5.72 | 33.7 |
| 16,384 | 177 | 33.1 | 139 | 174 | 32.4 | 153 |

The ztcl transform needs 0.73 to 0.89 times the time of the native C++ code of HEXL, and 4.2 to 5.9 times the time of its AVX512-IFMA code. The same table has NTL at 2.44, 8.48, and 40.2 microseconds forward with no AVX-512: 2.7 to 3.6 times as fast as ztcl.

### CKKS: Microsoft SEAL

Al Badawi and others, "PrivFT", Table 2: Microsoft SEAL 3.2 on a CPU server that the paper lists as a Xeon E5-2620, milliseconds. The paper gives the size of the modulus (200, 360, and 600 bits, the same as the sets of ztcl) and not the count of its primes, so the count of digits of the key switch can differ. The paper does not state the thread count of this table.

| Operation | n = 2^13, SEAL 3.2 | ztcl | n = 2^14, SEAL 3.2 | ztcl | n = 2^15, SEAL 3.2 | ztcl |
|---|---|---|---|---|---|---|
| Multiply + relinearize | 10.83 | 2.96 | 23.07 | 21.1 | 107.08 | 116 |
| Rescale | 5.60 | 0.57 | 11.85 | 2.68 | 41.29 | 10.3 |
| Rotate | 14.67 | 2.69 | 37.55 | 20.1 | 186.24 | 115 |

Against these numbers ztcl needs 0.27 to 1.09 times the time for a multiplication, 0.10 to 0.25 times for a rescale, and 0.18 to 0.62 times for a rotation. SEAL 3.2 is a version of 2019, and the CPU is older than this host. The HEXL paper gives no absolute times for a newer SEAL: it gives only the gain of HEXL in SEAL 3.6.5 at n = 8,192 (2.2 times for multiply + relinearize, 3.3 times for the rescale, 2.1 times for the rotation). The paper has one more set, n = 2^16 with 1,770 bits. The set of ztcl at 2^16 has 600 bits, so no comparison exists for it.

### CKKS: OpenFHE

No published table of OpenFHE with the time of each CKKS operation at these parameters was found. One candidate (IACR ePrint 2024/1059) was not read: the site refused the automated download.

### Gate bootstrap: TFHE-rs, the TFHE library, OpenFHE

The benchmark page of the TFHE-rs 0.4 documentation: an AWS m6i.metal with a Xeon Platinum 8375C (AVX-512). The page does not state the thread count.

| Library and set | Time of one gate | ztcl / library |
|---|---|---|
| TFHE-rs, `TFHE_LIB_PARAMETERS` (the set of ztcl) | 10.0 ms | 5.1 |
| TFHE-rs, `DEFAULT_PARAMETERS_KS_PBS` | 9.19 ms | 5.6 |
| TFHE library, `default_128bit_gate_bootstrapping_parameters`, spqlios-fma | 15.4 ms | 3.3 |
| OpenFHE 1.1.1, `STD128_OR`, GINX | 40.2 ms | 1.3 |
| OpenFHE 1.1.1, `STD128_OR`, GINX with Intel HEXL | 31.0 ms | 1.7 |
| ztcl, the set of the TFHE library | 51.4 ms | 1 |

The other libraries multiply the polynomials with a floating-point FFT of N / 2 complex numbers with AVX2 or AVX-512. ztcl uses an exact 64-bit NTT of N places. The FFT is the faster transform at this size, and it is the largest part of the difference.

## Where a GPU helps (ztcl issue 656)

1. The CKKS key switch. The two examples above are 13 and 12 key switches and a few small operations. A key switch at level l is (l + 1) * (l + 2) transforms plus the same count of row products. At n = 2^16 with 13 primes this is 182 transforms of 65,536 words, and each row is independent of the others. This is the best target: the PrivFT table reports 27 to 48 times for multiply + relinearize and 24 to 73 times for a rotation on one V100 against SEAL on a CPU. Hand-written kernels of step 1 of the issue are enough: one kernel for a batch of transforms and one for the sum of row products. The switch keys (182 MB each at 2^16) must stay in GPU memory.
2. The rescale and the encryption, with the same transform kernel.
3. The gates of TFHE in batches. One gate is 630 steps in sequence on 1,024 places, so a GPU does not make one gate faster. A circuit has many independent gates in each layer, and a GPU runs them in one batch.
4. A sequence on the GPU, such as the dot product: 12 rotations with no transfer between them. A ciphertext is 0.38 to 13 MB, so a transfer for each operation costs more than the small operations.

The kernels need a 64-bit product modulo a prime. Metal, Vulkan, and D3D12 have 64-bit integers and no high multiplication, so a kernel makes it from 32-bit products, as the AVX2 code does. WGSL has no 64-bit integer: a WebGPU kernel needs 32-bit limbs or primes below 2^31 with two times the rows. The typed kernels of step 2 of the issue need unsigned 64-bit and 32-bit types with wrapping products for this work.

Add, the encoder, and the decoder gain little: they are a small part of the time, and the encoder is a floating-point FFT of one row.
