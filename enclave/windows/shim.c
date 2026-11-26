/* The shim of ztcl-enclave.dll (ztcl#180): the configuration of the
 * image, DllMain, and the routine ztcl_run. The interpreter is in
 * ztcl-enclave-core.lib (src/enclave_core.zig). See docs/dev/enclave.md.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <winenclave.h>

#include "ztcl_enclave.h"

int32_t ztcl_core_run(const char *script, size_t script_len, uint64_t compute_limit, size_t mem_limit,
                      char *out, size_t out_cap, size_t *out_len);
void ztcl_core_report_data(const uint8_t *nonce, size_t nonce_len, uint64_t compute_limit, uint64_t mem_limit,
                           const uint8_t *caps, size_t caps_len, const char *script, size_t script_len,
                           uint8_t out[64]);

#ifdef ZTCL_ENCLAVE_DEBUG
#define ZTCL_POLICY (IMAGE_ENCLAVE_POLICY_STRICT_MEMORY | IMAGE_ENCLAVE_POLICY_DEBUGGABLE)
#else
#define ZTCL_POLICY IMAGE_ENCLAVE_POLICY_STRICT_MEMORY
#endif

/* Windows reads this before it runs any code of the image. */
const IMAGE_ENCLAVE_CONFIG __enclave_config = {
    sizeof(IMAGE_ENCLAVE_CONFIG),
    IMAGE_ENCLAVE_MINIMUM_CONFIG_SIZE,
    ZTCL_POLICY,
    0, /* NumberOfImports */
    0, /* ImportList */
    0, /* ImportEntrySize */
    {'z', 't', 'c', 'l'}, /* FamilyID */
    {'z', 't', 'c', 'l', '-', 'c', 'o', 'r', 'e'}, /* ImageID */
    1, /* ImageVersion */
    1, /* SecurityVersion */
    0x10000000, /* EnclaveSize: 256 MiB */
    2, /* NumberOfThreads */
    IMAGE_ENCLAVE_FLAG_PRIMARY_IMAGE,
};

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)instance;
    (void)reason;
    (void)reserved;
    return TRUE;
}

/* The buffers inside the enclave. One call runs at a time. */
static ztcl_enclave_request req;
static char script[ZTCL_ENCLAVE_MAX_SCRIPT];
static char out[ZTCL_ENCLAVE_MAX_OUT];
static uint8_t blob[ZTCL_ENCLAVE_MAX_BLOB];
static uint8_t report[ZTCL_ENCLAVE_MAX_REPORT];
static volatile LONG busy;

/* The capability list of the first version is empty. */
static const uint8_t caps[1] = {0};

static HRESULT run(void)
{
    HRESULT hr;
    size_t out_len = 0;
    UINT32 blob_len = 0, report_len = 0;
    uint8_t data[ENCLAVE_REPORT_DATA_LENGTH];

    if (req.script_len > sizeof(script) || req.out_cap > sizeof(out)) return E_INVALIDARG;
    hr = EnclaveCopyIntoEnclave(script, req.script, req.script_len);
    if (FAILED(hr)) return hr;
    req.code = ztcl_core_run(script, req.script_len, req.compute_limit, (size_t)req.mem_limit, out, req.out_cap, &out_len);
    req.out_len = (uint32_t)out_len;
    hr = EnclaveCopyOutOfEnclave(req.out, out, out_len);
    if (FAILED(hr)) return hr;
    if (req.code != 0) return S_OK;

    hr = EnclaveSealData(out, (UINT32)out_len, ENCLAVE_IDENTITY_POLICY_SEAL_SAME_IMAGE, 0, blob, sizeof(blob), &blob_len);
    if (FAILED(hr)) return hr;
    if (blob_len > req.blob_cap) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    hr = EnclaveCopyOutOfEnclave(req.blob, blob, blob_len);
    if (FAILED(hr)) return hr;
    req.blob_len = blob_len;

    ztcl_core_report_data(req.nonce, sizeof(req.nonce), req.compute_limit, req.mem_limit, caps, 0, script,
                          req.script_len, data);
    hr = EnclaveGetAttestationReport(data, report, sizeof(report), &report_len);
    if (FAILED(hr)) return hr;
    if (report_len > req.report_cap) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    hr = EnclaveCopyOutOfEnclave(req.report, report, report_len);
    if (FAILED(hr)) return hr;
    req.report_len = report_len;
    return S_OK;
}

static HRESULT unseal(void)
{
    HRESULT hr;
    UINT32 out_len = 0, flags = 0;

    if (req.blob_len > sizeof(blob) || req.out_cap > sizeof(out)) return E_INVALIDARG;
    hr = EnclaveCopyIntoEnclave(blob, req.blob, req.blob_len);
    if (FAILED(hr)) return hr;
    hr = EnclaveUnsealData(blob, req.blob_len, out, req.out_cap, &out_len, NULL, &flags);
    if (FAILED(hr)) return hr;
    hr = EnclaveCopyOutOfEnclave(req.out, out, out_len);
    if (FAILED(hr)) return hr;
    req.out_len = out_len;
    req.code = 0;
    return S_OK;
}

static HRESULT verify(void)
{
    HRESULT hr;

    if (req.report_len > sizeof(report)) return E_INVALIDARG;
    hr = EnclaveCopyIntoEnclave(report, req.report, req.report_len);
    if (FAILED(hr)) return hr;
    hr = EnclaveVerifyAttestationReport(ENCLAVE_TYPE_VBS, report, req.report_len);
    req.code = hr;
    return hr;
}

/* The routine of CallEnclave. `context` is a ztcl_enclave_request in the
 * memory of the host. Gives an HRESULT. */
void *CALLBACK ztcl_run(void *context)
{
    HRESULT hr;

    if (InterlockedCompareExchange(&busy, 1, 0) != 0) return (void *)(LONG_PTR)HRESULT_FROM_WIN32(ERROR_BUSY);
    hr = EnclaveCopyIntoEnclave(&req, context, sizeof(req));
    if (SUCCEEDED(hr)) {
        if (req.mode == ZTCL_ENCLAVE_RUN) hr = run();
        else if (req.mode == ZTCL_ENCLAVE_UNSEAL) hr = unseal();
        else if (req.mode == ZTCL_ENCLAVE_VERIFY) hr = verify();
        else hr = E_INVALIDARG;
    }
    if (FAILED(hr)) req.code = hr;
    /* The host gets back the lengths and the code. */
    if (FAILED(EnclaveCopyOutOfEnclave(context, &req, sizeof(req)))) hr = E_FAIL;
    InterlockedExchange(&busy, 0);
    return (void *)(LONG_PTR)hr;
}
