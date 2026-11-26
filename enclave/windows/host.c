/* The host test of ztcl-enclave.dll (ztcl#180): makes a VBS enclave,
 * loads the image, runs a script inside, prints the output and the sizes
 * of the sealed blob and the report, unseals the blob, and checks the
 * report. Each step prints its result, so a failed step shows the error
 * of Windows. See docs/dev/enclave.md.
 *
 * Usage: ztcl-enclave-host.exe [script]
 *        ztcl-enclave-host.exe -unseal
 *
 * A run writes the blob and the report into ztcl-enclave.blob and
 * ztcl-enclave.report. With -unseal, a new enclave unseals the blob.
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
        printf("%s: HRESULT 0x%08lx at line %lu of shim.c\n", step, (unsigned long)(LONG_PTR)ret, (unsigned long)req->step);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    int unseal_only = argc > 1 && strcmp(argv[1], "-unseal") == 0;
    const char *script = argc > 1 && !unseal_only ? argv[1] : "puts [expr {6*7}]";
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
    if (unseal_only) {
        /* A new enclave of the same image unseals the blob of an
         * earlier run. */
        FILE *f = fopen("ztcl-enclave.blob", "rb");
        if (f == NULL) {
            printf("no ztcl-enclave.blob\n");
            return 1;
        }
        req.blob_len = (uint32_t)fread(blob, 1, sizeof(blob), f);
        fclose(f);
        req.mode = ZTCL_ENCLAVE_UNSEAL;
        req.blob = blob;
        req.blob_cap = sizeof(blob);
        req.out = out;
        req.out_cap = sizeof(out);
        ok = call(routine, &req, "ztcl_run(unseal)");
        if (ok) printf("unsealed in a new enclave: %.*s", (int)req.out_len, out);
        TerminateEnclave(base, TRUE);
        DeleteEnclave(base);
        return ok ? 0 : 1;
    }
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
    {
        printf("code: %ld (0x%08lx)\noutput (%lu bytes): %.*s\n", (long)req.code, (unsigned long)req.code, (unsigned long)req.out_len, (int)(req.out_len < sizeof(out) ? req.out_len : 0), out);
        printf("sealed blob: %lu bytes\nreport: %lu bytes\n", (unsigned long)req.blob_len, (unsigned long)req.report_len);
    }

    if (ok && req.blob_len > 0) {
        uint32_t blob_len = req.blob_len, report_len = req.report_len;
        FILE *f = fopen("ztcl-enclave.blob", "wb");
        if (f != NULL) {
            fwrite(blob, 1, blob_len, f);
            fclose(f);
        }
        f = fopen("ztcl-enclave.report", "wb");
        if (f != NULL) {
            fwrite(report, 1, report_len, f);
            fclose(f);
        }
        printf("wrote ztcl-enclave.blob and ztcl-enclave.report\n");
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
