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

## Next

1. Sign the image with a self-signed certificate with the three EKUs of [enclave.md](enclave.md), and record the result of `LoadEnclaveImageW` with test signing off. The certificate goes into the certificate store of the user, so this step waits for the user's answer.
2. With the user's answer on test signing, record the result with it on: the output `42`, the sizes of the sealed blob and the report, the unsealed output, and the result of `EnclaveVerifyAttestationReport`.
