# The speed of TLS

This page has the measured speed of the TLS record layer of ztcl, the same AEADs in OpenSSL, and the plan to make the ztcl code as fast as the hardware allows. Correctness comes first: each change keeps the Wycheproof sets, the RFC 8448 traces, and the openssl and curl interop checks green.

## How to measure

```sh
tools/tls-bench.sh
```

`zig build tls-bench` seals and opens records of 16,384 bytes of application data with `record.Protection` (`src/tls/bench.zig`), in ReleaseFast, and prints the best of 5 runs. Then it seals and opens 16,384 bytes in place with AES-GCM of `aead.zig` alone, as `openssl speed` does. The clock is the CPU time of the thread, read once for each batch of 8 records, so other jobs on the machine change the numbers less. The script runs it for `-Dcpu=native` and `-Dcpu=baseline`, then `openssl speed -evp` with `-bytes 16384`. MB/s is 10^6 bytes of plaintext per second.

## Results

Intel Core i7-6700K at 4.00 GHz (AES-NI, PCLMULQDQ, AVX2; no VAES, no AVX-512), Linux, Zig 0.17.0, OpenSSL 3.6.5. The machine runs other jobs at the same time, so each number can be low by some percent. Each row of a table comes from one run of the script.

2026-11-27, after the run-time CPU dispatch and the AES-GCM of `src/crypto/x86_avx2.zig` (step 1 and the x86-64 part of step 2):

| AEAD | record seal, baseline | record open, baseline | alone, seal, baseline | alone, open, baseline | record seal, native | OpenSSL |
|---|---:|---:|---:|---:|---:|---:|
| AES-128-GCM | 3,474 | 2,791 | 3,485 | 3,476 | 3,457 | 3,538 |
| AES-256-GCM | 2,830 | 2,350 | 2,871 | 2,850 | 2,878 | 2,943 |
| ChaCha20-Poly1305 | 373 | 371 | | | 552 | 1,785 |

2026-11-27, before (`std.crypto` for each AEAD, the clock read for each record):

| AEAD | ztcl seal, native | ztcl open, native | ztcl seal, baseline | ztcl open, baseline | OpenSSL |
|---|---:|---:|---:|---:|---:|
| AES-128-GCM | 885 | 663 | 45 | 41 | 3,905 |
| AES-256-GCM | 787 | 578 | 34 | 31 | 3,030 |
| ChaCha20-Poly1305 | 550 | 448 | 268 | 231 | 1,895 |

With `-Dcpu=x86_64_v3`, AES-128-GCM was 51 MB/s: the x86-64-v3 level of Zig has no `aes` feature.

## What the numbers show

- The release builds use `-Dtarget=x86_64-linux` (and the other targets of `.github/workflows/release.yml`), and these targets have the baseline CPU. `std.crypto` picks AES-NI and PCLMULQDQ at compile time from the target features, so a release binary used the software AES: about 20 times slower than the native build.
- build.zig now compiles `src/crypto/x86_avx2.zig` and `src/crypto/arm_aes.zig` as modules with more CPU features than the target. A module has its own `-mcpu`, and LLVM gives each function the features of its module, so one binary has both the baseline code and the AES-NI code. `src/tls/aead.zig` reads CPUID once and picks the code. The baseline build and the native build now have the same AES-GCM speed.
- AES-GCM alone is at 98 percent of OpenSSL on this CPU. The loop encrypts 8 blocks and folds 8 blocks into GHASH with one reduction in each step, in one pass over the data.
- The record `seal` of AES-GCM reads the content where it is: the content type and the padding go to the AEAD as a second input of at most 256 bytes. The record `open` is about 20 percent slower than the AEAD alone: it decrypts into a second buffer and then scans for the content type. The scan now compares 32 bytes at a time.
- ChaCha20-Poly1305 is still the code of `std.crypto`, and its baseline build has no AVX2.

## Plan

In order of the gain for each change. Each step has its own PR with the bench numbers before and after.

1. Done. Runtime CPU dispatch. The AEAD code reads CPUID (x86-64) or the HWCAP bits (aarch64 Linux, always on for aarch64 macOS) once, and calls the AES-NI and PCLMUL code in a baseline build.
2. Done for AES-NI with 128-bit vectors; the VAES path is open. Own AES-GCM for x86-64: 8 blocks of AES-NI in flight, GHASH with PCLMULQDQ on 4 to 8 blocks with one reduction (the aggregated reduction of the Intel white paper on GCM), encrypt and GHASH in one pass over the data, and the tag check in the same pass as the decrypt for `open`. A VAES and VPCLMULQDQ path with 256-bit and 512-bit vectors for CPUs that have them. Target: the OpenSSL column.
3. Code done in `src/crypto/arm_aes.zig`; it passes the tests in QEMU (`qemu-aarch64-static`), and has no speed number on real hardware yet. AES-GCM on aarch64 with the ARMv8 crypto extensions (AESE, AESMC, PMULL), the same pipelining.
4. ChaCha20-Poly1305 with 4 and 8 blocks at a time in AVX2 (and NEON on aarch64), and Poly1305 with vector limbs.
5. Records with no copies: seal in place in the send buffer, open in place in the receive buffer, and several records in one write.
6. io_uring: registered buffers, multishot recv with provided buffers, and `send_zc` for large writes. Measure each one, and keep only the ones that gain.
7. kTLS on Linux (`setsockopt(TCP_ULP, "tls")` and `TLS_TX`/`TLS_RX`) after the handshake, as an option: the kernel does the record layer, and `sendfile` works on a TLS socket. It needs the kernel module `tls`; with no module, the code stays in user space.
8. HTTP/2 framing and HPACK read the frames in place in the receive buffer, with no copy of a header block.

The full benchmarks against a reference HTTP/2 server come with the HTTP/2 server (task 29). `openssl s_time` against `ztcl::tls` comes with step 5.
