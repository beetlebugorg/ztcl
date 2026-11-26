/* The host test of ztcl-enclave.dll (ztcl#180): makes a VBS enclave,
 * loads the image, runs a script inside, prints the output and the sizes
 * of the sealed blob and the report, unseals the blob, and checks the
 * report. Each step prints its result, so a failed step shows the error
 * of Windows. See docs/dev/enclave.md.
 *
 * Usage: ztcl-enclave-host.exe [script]
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <windows.h>
#include <enclaveapi.h>
#include <stdio.h>
#include <string.h>

#include "ztcl_enclave.h"

#define ENCLAVE_SIZE 0x10000000

static void fail(const char *step)
{
    DWORD e = GetLastError();
    char msg[512] = "";
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, e, 0, msg, sizeof(msg), NULL);
    printf("%s: error %lu (0x%08lx) %s", step, e, e, msg);
    if (msg[0] == 0) printf("\n");
}

static int call(void *routine, ztcl_enclave_request *req, const char *step)
{
    void *ret = NULL;
    if (!CallEnclave((LPENCLAVE_ROUTINE)routine, req, TRUE, &ret)) {
        fail(step);
        return 0;
    }
    if (FAILED((HRESULT)(LONG_PTR)ret)) {
        printf("%s: HRESULT 0x%08lx\n", step, (unsigned long)(LONG_PTR)ret);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    const char *script = argc > 1 ? argv[1] : "puts [expr {6*7}]";
    static char out[1 << 16];
    static uint8_t blob[1 << 16];
    static uint8_t report[ZTCL_ENCLAVE_MAX_REPORT];
    ENCLAVE_CREATE_INFO_VBS create = {0};
    ENCLAVE_INIT_INFO_VBS init = {0};
    ztcl_enclave_request req;
    void *base, *routine;
    DWORD err = 0;
    int ok;

    printf("IsEnclaveTypeSupported(VBS): %d\n", IsEnclaveTypeSupported(ENCLAVE_TYPE_VBS));
    memcpy(create.OwnerID, "ztcl-enclave-host", 17);
    base = CreateEnclave(GetCurrentProcess(), NULL, ENCLAVE_SIZE, 0, ENCLAVE_TYPE_VBS, &create, sizeof(create), &err);
    if (base == NULL) {
        fail("CreateEnclave");
        return 1;
    }
    printf("CreateEnclave: ok\n");
    if (!LoadEnclaveImageW(base, L"ztcl-enclave.dll")) {
        fail("LoadEnclaveImageW");
        DeleteEnclave(base);
        return 1;
    }
    printf("LoadEnclaveImageW: ok\n");
    init.Length = sizeof(init);
    init.ThreadCount = 1;
    if (!InitializeEnclave(GetCurrentProcess(), base, &init, sizeof(init), &err)) {
        fail("InitializeEnclave");
        DeleteEnclave(base);
        return 1;
    }
    printf("InitializeEnclave: ok\n");
    routine = (void *)GetProcAddress((HMODULE)base, "ztcl_run");
    if (routine == NULL) {
        fail("GetProcAddress(ztcl_run)");
        TerminateEnclave(base, TRUE);
        DeleteEnclave(base);
        return 1;
    }

    memset(&req, 0, sizeof(req));
    req.mode = ZTCL_ENCLAVE_RUN;
    req.script = script;
    req.script_len = (uint32_t)strlen(script);
    req.compute_limit = 1000000;
    req.mem_limit = 32u << 20;
    memcpy(req.nonce, "nonce of the ztcl enclave spike", 31);
    req.out = out;
    req.out_cap = sizeof(out);
    req.blob = blob;
    req.blob_cap = sizeof(blob);
    req.report = report;
    req.report_cap = sizeof(report);
    ok = call(routine, &req, "ztcl_run(run)");
    if (ok) {
        printf("code: %ld\noutput: %.*s", (long)req.code, (int)req.out_len, out);
        printf("sealed blob: %lu bytes\nreport: %lu bytes\n", (unsigned long)req.blob_len, (unsigned long)req.report_len);
    }

    if (ok && req.blob_len > 0) {
        uint32_t blob_len = req.blob_len, report_len = req.report_len;
        memset(out, 0, sizeof(out));
        req.mode = ZTCL_ENCLAVE_UNSEAL;
        req.blob_len = blob_len;
        if (call(routine, &req, "ztcl_run(unseal)")) printf("unsealed: %.*s", (int)req.out_len, out);
        req.mode = ZTCL_ENCLAVE_VERIFY;
        req.report_len = report_len;
        if (call(routine, &req, "ztcl_run(verify)")) printf("EnclaveVerifyAttestationReport: ok\n");
    }

    TerminateEnclave(base, TRUE);
    DeleteEnclave(base);
    return ok ? 0 : 1;
}
