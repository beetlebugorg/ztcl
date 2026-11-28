# References for ztcl::fhe

`src/fhe/` uses these sources. The code is new Zig code. No source code of Microsoft SEAL, OpenFHE, PALISADE, HElib, Lattigo, TFHE-rs, Concrete, Intel HEXL, NTL, or NFLlib was read for this work, and none of them was installed or run.

Two entries below are projects and not papers: HEAAN and the TFHE library. The author of this prototype is an AI model. It wrote the encoder and the TFHE parameter set from what it knows of these two projects from its training, with no file of them open during the work. Each entry says what came from the project. A person must review the two entries before this prototype leaves the draft state: the license of HEAAN does not allow commercial use.

## The transform

Patrick Longa and Michael Naehrig, "Speeding up the Number Theoretic Transform for Faster Ideal Lattice-Based Cryptography", CANS 2016. https://eprint.iacr.org/2016/504

**How ztcl uses it:** the negacyclic transform with the powers of the 2n-th root in bit-reversed order: the Cooley-Tukey form forward and the Gentleman-Sande form for the inverse, with no separate multiplication by the powers of the root (`ntt.zig`).

David Harvey, "Faster arithmetic for number-theoretic transforms", Journal of Symbolic Computation 60, 2014. https://arxiv.org/abs/1205.2926

**How ztcl uses it:** the butterflies with lazy reduction, where the values stay below 4q, and the multiplication by a constant with one precomputed word. Harvey gives this multiplication as the method of Victor Shoup in NTL. ztcl uses the description in the paper.

Paul Barrett, "Implementing the Rivest Shamir and Adleman Public Key Encryption Algorithm on a Standard Digital Signal Processor", CRYPTO 1986.

**How ztcl uses it:** the reduction of a 128-bit product with the precomputed word floor(2^128 / q) (`Modulus.reduce128`).

Jonathan Sorenson and Jonathan Webster, "Strong pseudoprimes to twelve prime bases", Mathematics of Computation 86, 2017. https://arxiv.org/abs/1509.00864

**How ztcl uses it:** the Miller-Rabin test with the first 12 primes as bases is exact for each 64-bit integer (`isPrime`).

## CKKS

Jung Hee Cheon, Andrey Kim, Miran Kim, and Yongsoo Song, "Homomorphic Encryption for Arithmetic of Approximate Numbers", ASIACRYPT 2017. https://eprint.iacr.org/2016/421

**How ztcl uses it:** the scheme: the encoding by the canonical embedding, the encryption, the multiplication with relinearization, the rescale, and the rotation by a Galois automorphism (`ckks.zig`).

Jung Hee Cheon, Kyoohyung Han, Andrey Kim, Miran Kim, and Yongsoo Song, "A Full RNS Variant of Approximate Homomorphic Encryption", SAC 2018. https://eprint.iacr.org/2018/931

**How ztcl uses it:** the modulus as a product of word-size primes, one row of residues for each prime, and the rescale by one prime.

Craig Gentry, Shai Halevi, and Nigel P. Smart, "Homomorphic Evaluation of the AES Circuit", CRYPTO 2012. https://eprint.iacr.org/2012/099

**How ztcl uses it:** key switching with a special modulus P: the key encrypts P times the secret, and the switch divides by P.

Jean-Claude Bajard, Julien Eynard, M. Anwar Hasan, and Vincent Zucca, "A Full RNS Variant of FV like Somewhat Homomorphic Encryption Schemes", SAC 2016. https://eprint.iacr.org/2016/510

**How ztcl uses it:** the digits of the key switch are the residue rows of the RNS form: one digit for each prime.

Andrey Kim, Antonis Papadimitriou, and Yuriy Polyakov, "Approximate Homomorphic Encryption with Reduced Approximation Error", CT-RSA 2022. https://eprint.iacr.org/2020/1118

**How ztcl uses it:** one exact scale for each level, and the selection of each prime near the square of the scale of its level over the target scale, so the scale does not drift (`Context.init`).

Harvey L. Garner, "The Residue Number System", IRE Transactions on Electronic Computers, 1959.

**How ztcl uses it:** the mixed-radix digits that give the integer of a coefficient from its residues in the decoder (`liftCentered`).

HEAAN, Seoul National University (the library of the CKKS authors). https://github.com/snucrypto/HEAAN

**License:** Creative Commons Attribution-NonCommercial 3.0. ztcl has no file and no text of HEAAN.

**How ztcl uses it:** the encoder of `ckks.zig` (`fftSpecial`, `fftSpecialInv`) is an FFT over the roots in the order of the powers of 5, with the slot i at the root 5^i. This order makes a rotation of the slots one automorphism. The method is the encoder of HEAAN, written again from memory. The paper "Bootstrapping for Approximate Homomorphic Encryption" (Cheon, Han, Kim, Kim, and Song, EUROCRYPT 2018, https://eprint.iacr.org/2018/153) describes the order of the slots.

Martin Albrecht and others, "Homomorphic Encryption Standard", HomomorphicEncryption.org, November 2018. https://homomorphicencryption.org/standard/

**How ztcl uses it:** the largest modulus for each ring size at 128 bits of classical security with a ternary secret (Table 1: 218 bits at n = 2^13, 438 bits at 2^14, 881 bits at 2^15), the ternary secret, and the error deviation 3.2. The table stops at n = 2^15. ztcl uses the limit of 2^15 for n = 2^16. These numbers are from memory of the standard. The table was not open during the work.

## TFHE

Ilaria Chillotti, Nicolas Gama, Mariya Georgieva, and Malika Izabachene, "TFHE: Fast Fully Homomorphic Encryption over the Torus", Journal of Cryptology 33, 2020. https://eprint.iacr.org/2018/421

The same authors, "Faster Fully Homomorphic Encryption: Bootstrapping in less than 0.1 Seconds", ASIACRYPT 2016. https://eprint.iacr.org/2016/870

**How ztcl uses it:** the LWE and ring ciphertexts on the torus, the gadget decomposition, the external product, the blind rotation, the extraction, the key switch, and the gates as a sum and one bootstrap (`tfhe.zig`). ztcl multiplies the polynomials with an exact NTT modulo one 59-bit prime in place of the floating-point FFT of the paper.

The TFHE library of the same authors. https://tfhe.github.io/tfhe/

**License:** Apache-2.0. ztcl has no file and no text of the library.

**How ztcl uses it:** the parameter set `lib_128` (n = 630, N = 1024, l = 3, Bg = 2^7, key switch length 8 with base 4, deviations 2^-15 and 2^-25) and the constants of the gates are the values of the library for 128 bits of security, from memory. The security estimate of this set is the estimate of the authors of the library. This work did not run a lattice estimator.

## The logistic function

Miran Kim, Yongsoo Song, Shuang Wang, Yuhou Xia, and Xiaoqian Jiang, "Secure Logistic Regression Based on Homomorphic Encryption: Design and Evaluation", JMIR Medical Informatics, 2018. https://eprint.iacr.org/2018/074

**How ztcl uses it:** the polynomial 0.5 + 0.197 y - 0.004 y^3, a least-squares fit to the logistic function on [-8, 8] (`fhe.sigmoid3`).

## The published times of other libraries

docs/dev/fhe.md compares the measured times with these published numbers. No other use.

Fabian Boemer, Sejun Kim, Gelila Seifu, Fillipe D. M. de Souza, and Vinodh Gopal, "Intel HEXL: Accelerating Homomorphic Encryption with Intel AVX512-IFMA52", WAHC 2021. https://arxiv.org/abs/2103.16400 (Tables 1 and 2: the transform.)

Ahmad Al Badawi, Louie Hoang, Chan Fook Mun, Kim Laine, and Khin Mi Mi Aung, "PrivFT: Private and Fast Text Classification with Homomorphic Encryption", IEEE Access, 2020. https://arxiv.org/abs/1908.06972 (Table 2: the CKKS operations of Microsoft SEAL 3.2 on a CPU.)

Zama, "TFHE-rs documentation, Benchmarks", version 0.4. https://docs.zama.org/tfhe-rs/0.4-1/getting-started/benchmarks (The gate times of TFHE-rs, the TFHE library, and OpenFHE 1.1.1 on one machine.)
