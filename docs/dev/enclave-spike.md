# The spike of the VBS enclave (ztcl#180)

The results of the spike of [enclave.md](enclave.md), on the Windows test machine of the project: Windows 11 Home 25H2, build 26200, with VBS and memory integrity on, Secure Boot off, and test signing off.

## Build

`pwsh enclave/windows/build.ps1` builds two files into `zig-out/enclave`:

- `ztcl-enclave.dll`, the enclave image (1,159,680 bytes). `zig build enclave-core` builds the interpreter with no capability for the target `x86_64-uefi`, a static library of COFF objects with compiler-rt and no import. The target `x86_64-freestanding` gives an ELF object, which `link.exe` refuses. `link.exe` of MSVC 14.44 links that library with `enclave/windows/shim.c`, the enclave CRT, `vertdll.lib`, `bcrypt.lib`, and `ucrt.lib` of `ucrt_enclave`, and `veiid.exe` binds the imports.
- `ztcl-enclave-host.exe`, the host test (`enclave/windows/host.c`).

The image imports only `vertdll.dll` and `ucrtbase_enclave.dll`. Its load configuration has the enclave configuration: the policy `IMAGE_ENCLAVE_POLICY_STRICT_MEMORY` (2), an enclave size of 256 MiB, the flag `IMAGE_ENCLAVE_FLAG_PRIMARY_IMAGE`, and two enclave import descriptors from `veiid.exe`.

## Run with no signature

| Step | Result |
|---|---|
| `IsEnclaveTypeSupported(ENCLAVE_TYPE_VBS)` | 1 |
| `CreateEnclave` (256 MiB, `ENCLAVE_TYPE_VBS`, flags 0) | ok |
| `LoadEnclaveImageW(L"ztcl-enclave.dll")` | error 577, `ERROR_INVALID_IMAGE_HASH`: "Windows cannot verify the digital signature for this file." |

So Windows 11 Home makes VBS enclaves, and the next step needs a signed image.

## Run with a self-signed signature

The user said yes to the certificate and to test signing (2026-11-26). The certificate, `CN=ztcl enclave development`, is in the store `Cert:\CurrentUser\My`, with the EKUs `1.3.6.1.5.5.7.3.3` (code signing), `1.3.6.1.4.1.311.76.57.1.15` (enclave), and `1.3.6.1.4.1.311.97.4120.180.209.2026` (author). It signs the image:

```
signtool sign /ph /fd SHA256 /sha1 <thumbprint> ztcl-enclave.dll
```

`signtool` signs it, with the warning "VBS enclave support is changing and updating your VBS enclave may cause you to lose support on older OSes" and a link to the page of Microsoft on the change.

| Step | Test signing off |
|---|---|
| `CreateEnclave` | ok |
| `LoadEnclaveImageW` | error 577, `ERROR_INVALID_IMAGE_HASH`, as with no signature |

So a self-signed enclave needs test signing, as the guide of Microsoft says.

## Run with test signing on

The user turned test signing on (`bcdedit /set testsigning on` and a restart, 2026-11-26). The options of the boot then have `TESTSIGNING`. The run of `ztcl-enclave-host.exe` with the self-signed image:

| Step | Result |
|---|---|
| `CreateEnclave` | ok |
| `LoadEnclaveImageW` | ok |
| `InitializeEnclave` (1 thread) | ok |
| `ztcl_run`: `puts [expr {6*7}]` | code 0, output `42` |
| `EnclaveSealData` (the same image) | a blob of 231 bytes |
| `EnclaveGetAttestationReport` | a report of 936 bytes |
| `EnclaveUnsealData`, the same enclave | `42` |
| `EnclaveUnsealData`, a new enclave of the same image (`-unseal`) | `42` |
| `EnclaveVerifyAttestationReport(ENCLAVE_TYPE_VBS)` | ok |
| `puts [string repeat ab 3]; error boom` | code 1, the message `boom` |

### What the spike found

- `EnclaveUnsealData` gives `E_INVALIDARG` for a NULL buffer of size 0, and for a buffer of 64 KiB or 1 MiB with a blob of 231 bytes. It unseals into a buffer of the exact size, of 64 bytes, or of 4,096 bytes. The shim gives it the size of the blob, since the data is shorter than its blob. `EnclaveSealData` and `EnclaveGetAttestationReport` accept a NULL buffer of size 0 and give the size.
- The report starts with its size (`0x3a8`, 936). It has the owner id of `CreateEnclave` (`ztcl-enclave-host`), the family id (`ztcl`) and the image id (`ztcl-core`) of the configuration of the image, and the name and a hash of each module: `ztcl-enclave.dll`, `vertdll.dll`, and `ucrtbase_enclave.dll`. A signature ends it. The format of the fields is still an open item of [enclave.md](enclave.md).
- The image needs about 1.2 MB, and the enclave runs the interpreter on its arena of 48 MiB with no call to the host.

## Next

1. Test signing off again (`bcdedit /set testsigning off` and a restart), and the certificate out of the store, when the user agrees.
2. `ztcl::enclave` as commands of the interpreter inside the enclave, in place of the fixed steps of the shim.
3. The host side in Zig (`src/enclave_windows.zig`), and a test that skips with no VBS enclave.
