# Plan: ztcl in enclaves and confidential VMs (ztcl#180)

The goal of ztcl#180: run a script where the host cannot see or change it, and give a remote party a proof that exactly this runtime ran exactly this script with exactly these limits and capabilities. The targets of the issue are confidential VMs (SEV-SNP, TDX), AWS Nitro Enclaves, Intel SGX, and the key stores of Apple and TPMs. This page starts with the target of Windows: VBS enclaves. The other targets get their sections from the sessions that work on them.

## Windows: VBS enclaves

A VBS enclave is a DLL that runs in virtual trust level 1 (VTL1), which the hypervisor of Windows keeps apart from the normal kernel (VTL0). The process of the host loads it, calls its exported routines, and cannot read or write its memory. Windows 11 build 26100.2314 and later and Windows Server 2025 run enclaves of third parties, with VBS and memory integrity (HVCI) on. The Windows test machine of this project (Windows 11 Home 25H2, build 26200) reports `IsEnclaveTypeSupported(ENCLAVE_TYPE_VBS)` as true and has no SGX (ztcl#180, the comment of 2026-11-26).

### Threat model

- Trusted: the hypervisor and the secure kernel of Windows, the CPU, and the code of the enclave image (its measurement is in each attestation report).
- Untrusted: the host process, the normal kernel and its drivers, and an administrator of the machine. They can stop the enclave, refuse to run it, give it any input, and see each byte that leaves it. They cannot read its memory, change its code, or forge its reports and sealed blobs.
- Out of scope in the first version: side channels of the CPU (cache timing, speculative execution), a malicious hypervisor, and denial of service.

### The image

- The enclave runs ztcl with no capability: the freestanding core of the interpreter, the parser, the compute and memory limits, and no host access. That core is the same code as the WebAssembly build, so it needs no system call.
- Zig builds the core as an object for `x86_64-windows-msvc` with no standard I/O. A small shim in C (or Zig) has `DllMain`, the exported routines, and the configuration of the image. `link.exe` of MSVC links them, because the Zig linker has no `/ENCLAVE`:
  - `/ENCLAVE /INCREMENTAL:NO /INTEGRITYCHECK /GUARD:MIXED /NODEFAULTLIB`
  - `libcmt.lib` and `libvcruntime.lib` of the enclave CRT of MSVC (`VC/Tools/MSVC/<version>/lib/x64/enclave`), `vertdll.lib` and `bcrypt.lib` of the SDK, and `ucrt.lib` of `ucrt_enclave`. No other platform library runs in an enclave.
  - A global `const IMAGE_ENCLAVE_CONFIG __enclave_config` with the family and image ids of ztcl, the image version, the security version, the enclave size, the thread count, `IMAGE_ENCLAVE_FLAG_PRIMARY_IMAGE`, and `IMAGE_ENCLAVE_POLICY_STRICT_MEMORY` (so each access to host memory goes through the copy functions).
  - `veiid.exe` of the SDK binds the import ids after the link.
- The memory of the interpreter is a fixed arena in the image, the size of the memory limit, so the enclave asks the host for no memory.
- Debug builds have `IMAGE_ENCLAVE_POLICY_DEBUGGABLE`. A release image never does, because a debugger of VTL0 can read a debuggable enclave.

### The host side

In the process of the embedder (a part of `src/enclave_windows.zig`, linked with `onecore.lib`):

1. `CreateEnclave(GetCurrentProcess(), null, size, 0, ENCLAVE_TYPE_VBS, &info, sizeof(ENCLAVE_CREATE_INFO_VBS), null)`, where `size` is a multiple of 2 MB and `info` is `ENCLAVE_CREATE_INFO_VBS { Flags, OwnerID[32] }`: `Flags` is 0 in a release and `ENCLAVE_VBS_FLAG_DEBUG` in a debug build, and the owner id is the hash of the embedder.
2. `LoadEnclaveImageW(base, L"ztcl-enclave.dll")`.
3. `InitializeEnclave(GetCurrentProcess(), base, &init, sizeof(ENCLAVE_INIT_INFO_VBS), null)` with `ENCLAVE_INIT_INFO_VBS { Length, ThreadCount }`. Windows calls `DllMain` of the image here.
4. `GetProcAddress` of the exported routine on the image, then `CallEnclave(routine, &request, TRUE, &result)`. A routine has the form `void *CALLBACK routine(void *context)`.
5. `TerminateEnclave(base, TRUE)` and `DeleteEnclave(base)` at the end.

### The calls

- One routine `ztcl_run(void *request)`. The request is in host memory: the script, the compute and memory limits, the capability list, a nonce, and room for the output. The enclave copies it in with `EnclaveCopyIntoEnclave`, checks each length against its arena, runs the script, and copies the output, the sealed blobs, and the report out with `EnclaveCopyOutOfEnclave`.
- In the first version the script has no capability, so the enclave makes no call out. Later, each capability that a script gets (for example the clock or a channel to the host) is one callback of the host that the enclave calls with `CallEnclave`. The list of callbacks is fixed at `InitializeEnclave` and is part of the measured input, so a script cannot reach a capability that the report does not show, and each byte that crosses is one that the host could see anyway.

### `ztcl::enclave`

Inside the enclave, a module with three commands:

| Command | Windows call |
|---|---|
| `ztcl::enclave seal ?-policy image\|author\|family? DATA` | `EnclaveSealData(data, size, policy, 0, blob, cap, &size)` with `ENCLAVE_IDENTITY_POLICY_SEAL_SAME_IMAGE` by default (`SAME_AUTHOR`, `SAME_FAMILY` with the option) |
| `ztcl::enclave unseal BLOB` | `EnclaveUnsealData`, with the error of a blob of another identity |
| `ztcl::enclave attest ?NONCE?` | `EnclaveGetAttestationReport(report_data, buf, cap, &size)`, where the 64 bytes of `report_data` are the SHA-512 of the nonce, the script, the limits, and the capability list |
| `ztcl::enclave identity` | `EnclaveGetEnclaveInformation`: the image id, the family id, the unique id, and the author id |

The runtime policy of `EnclaveSealData` is 0, so a debuggable enclave cannot unseal the blobs of a release enclave.

### Verification

`ztcl verify-attestation` (a command of the plan of ztcl#180) checks a VBS report: `EnclaveVerifyAttestationReport(ENCLAVE_TYPE_VBS, report, size)` on a Windows machine, the image id and the unique id against the published measurement of the release, and the report data against the SHA-512 of the nonce, the script, the limits, and the capabilities. Reproducible builds (ztcl#40) let anyone compute the unique id of a release from its source. A verifier off Windows needs the format of the report and the certificate chain of its signing key, an open item below.

### Signing

- **Development.** A self-signed certificate with three EKUs: code signing `1.3.6.1.5.5.7.3.3`, the enclave EKU `1.3.6.1.4.1.311.76.57.1.15`, and an author EKU `1.3.6.1.4.1.311.97.X.Y.Z` with X above 999. `signtool sign /ph /fd SHA256` signs the DLL with page hashes. Microsoft's guide says that such an enclave loads only on a machine with test signing on, a boot option of Windows.
- **Release.** Azure Trusted Signing with its VBS enclave certificate profile signs the image, and each machine with VBS loads it with no setting.
- **This machine.** Test signing is a change of the security settings of the system, so the spike asks the user before it is turned on. With test signing off, the spike can still build, sign, and call `LoadEnclaveImageW`, and record the error of Windows. The guide does not say whether Windows 11 Home loads test-signed enclaves, so that is the first fact for the spike to find.

### The spike

1. Build `ztcl-enclave.dll` with the core of ztcl, the shim, and `ztcl_run`, sign it with a self-signed certificate, and load it from a host test program.
2. Run `puts [expr {6*7}]` inside, and give back the output `42`, a blob of `ztcl::enclave seal` of the output, and a report of `ztcl::enclave attest` with a nonce from the host.
3. Unseal the blob in a second run of the same image, and check the report with `EnclaveVerifyAttestationReport`.
4. Record each result in `docs/dev/enclave-spike.md`: what loads with test signing off, and, after the user's answer, what loads with it on.

### Open items

- The format of a VBS attestation report and the root of its signing key, for a verifier on another system.
- Whether Azure Attestation or another service verifies VBS reports of third parties.
- The cost of a call into the enclave, for the design of the callbacks.
