# Module ztcl::fhe

`ztcl::fhe` computes on encrypted data. A script encrypts numbers, a second party adds and multiplies the ciphertexts with no key that decrypts, and the owner of the secret key decrypts the result. The module has two schemes:

- CKKS encrypts a vector of real numbers. Each operation works on all slots of the vector, and the result is approximate: the error is small and it grows with each multiplication.
- TFHE encrypts one bit. Each gate gives an exact result, and each gate refreshes its output, so a circuit has no depth limit.

The module is a prototype. It is in a build only with `zig build -Dmod-fhe=true`. The code is not constant time, it does not clear secret data from freed memory, and no person reviewed it. Do not protect real data with it. [The developer page](../dev/fhe.md) has the design, the parameter sets, and the measured times. [References](../references/fhe.md) lists the sources.

```tcl
package require ztcl::fhe
set ctx  [ztcl::fhe context ckks]
set keys [ztcl::fhe keys $ctx -sum 4]
set a [ztcl::fhe encrypt $keys {1.5 2.0 -3.0 0.25}]
set b [ztcl::fhe encrypt $keys {2.0 0.5 1.0 4.0}]
puts [ztcl::fhe decrypt $keys [ztcl::fhe add $a $b] 4]   ;# about 3.5 2.5 -2.0 4.25
puts [ztcl::fhe decrypt $keys [ztcl::fhe mul $a $b] 4]   ;# about 3.0 1.0 -3.0 1.0
puts [ztcl::fhe decrypt $keys [ztcl::fhe dot $a $b 4] 1] ;# about 2.0
```

The module needs no capability. The memory of its objects counts against the memory limit of the interpreter, and each operation uses compute units.

## Synopsis

```tcl
package require ztcl::fhe
ztcl::fhe context ckks ?-n SIZE? ?-levels COUNT?
ztcl::fhe context tfhe
ztcl::fhe keys CONTEXT ?-rotations LIST? ?-sum COUNT?
ztcl::fhe encrypt KEYS VALUES
ztcl::fhe decrypt KEYS CIPHERTEXT ?COUNT?
ztcl::fhe add CIPHERTEXT OTHER
ztcl::fhe mul CIPHERTEXT OTHER
ztcl::fhe rotate CIPHERTEXT STEPS
ztcl::fhe dot CIPHERTEXT OTHER ?COUNT?
ztcl::fhe gate NAME A B
ztcl::fhe not A
ztcl::fhe info OBJECT
ztcl::fhe free ?OBJECT ...?
```

A context, a key set, and a ciphertext are objects with the names `fhe0`, `fhe1`, and so on. `free` frees an object. The end of the interpreter frees each object that is left.

## Commands

### context

`ztcl::fhe context ckks` makes a CKKS context. `-n` is the size of the ring: 8192 (the default), 16384, 32768, or 65536. A vector has `SIZE / 2` slots. `-levels` is the count of multiplications in sequence that a new ciphertext allows. The defaults are 2, 6, 12, and 12 levels. Each level adds 40 bits to the modulus. The command fails when the modulus is above the limit of the HomomorphicEncryption.org standard for 128-bit security at the size: 218, 438, 881, and 881 bits.

`ztcl::fhe context tfhe` makes a TFHE context with the 128-bit parameter set of the TFHE library.

### keys

Makes the keys of a context: the secret key, and the public keys of the operations. For CKKS, `-rotations` is a list of rotation steps, and `-sum COUNT` adds the rotations that `dot` needs for `COUNT` values. Each rotation step has its own key. `rotate` and `dot` fail with the error code `ZTCL FHE NOKEY` for a step with no key.

A key set of TFHE is 118 MB. A key set of CKKS is 2.1 MB at the size 8192 with no rotation, and each rotation adds 1.5 MB. The developer page has the sizes of the other sets.

### encrypt

For CKKS, `VALUES` is a list of real numbers, at most one for each slot. The other slots are 0. For TFHE, `VALUES` is one integer: 0 is false and each other integer is true.

### decrypt

For CKKS, gives the list of the slots, or the first `COUNT` slots. For TFHE, gives 0 or 1. The ciphertext must be of the key set `KEYS`.

### add

Gives a new ciphertext with the sum in each slot. `OTHER` is a ciphertext, one number for all slots, or a list of numbers.

### mul

Gives a new ciphertext with the product in each slot. `OTHER` is a ciphertext, one number, or a list of numbers. The result is one level below its inputs. The command fails with the error code `ZTCL FHE NOLEVEL` when the ciphertext is at level 0. `add` and `mul` accept ciphertexts of different levels.

### rotate

Gives a new ciphertext with the slots rotated to the left by `STEPS`: slot i of the result is slot i + `STEPS` of the input. A negative step rotates to the right.

### dot

Gives a ciphertext with the dot product of the first `COUNT` slots in slot 0. `COUNT` is a power of two. The default is the count of slots, or for a list the next power of two from its length. The key set needs `-sum COUNT`.

### gate

Gives the result of a gate on two TFHE ciphertexts. `NAME` is `nand`, `and`, `or`, `xor`, `nor`, or `xnor`.

### not

Gives the negation of a TFHE ciphertext. This command is fast: it has no bootstrap.

### info

Gives a dictionary with the kind of an object, its scheme, and its sizes in bytes. A CKKS ciphertext has its level.

### free

Frees each object. The command fails with the error code `ZTCL FHE INUSE` for a context that has key sets and for a key set that has ciphertexts.

## An encrypted logistic regression score

The model is plain and the features are encrypted. The polynomial 0.5 + 0.197 y - 0.004 y^3 is near the logistic function for y from -8 to 8.

```tcl
package require ztcl::fhe
set ctx  [ztcl::fhe context ckks -n 16384]
set keys [ztcl::fhe keys $ctx -sum 4]
set x [ztcl::fhe encrypt $keys {0.5 -1.25 2.0 0.75}]

set y  [ztcl::fhe add [ztcl::fhe dot $x {0.8 0.1 -0.4 1.5}] 0.3]
set y3 [ztcl::fhe mul [ztcl::fhe mul $y $y] [ztcl::fhe mul $y -0.004]]
set score [ztcl::fhe add [ztcl::fhe add $y3 [ztcl::fhe mul $y 0.197]] 0.5]
puts [ztcl::fhe decrypt $keys $score 1]
```

## A one-bit adder with TFHE

```tcl
package require ztcl::fhe
set keys [ztcl::fhe keys [ztcl::fhe context tfhe]]
set a [ztcl::fhe encrypt $keys 1]
set b [ztcl::fhe encrypt $keys 1]
puts [ztcl::fhe decrypt $keys [ztcl::fhe gate xor $a $b]]   ;# the sum bit: 0
puts [ztcl::fhe decrypt $keys [ztcl::fhe gate and $a $b]]   ;# the carry bit: 1
```
