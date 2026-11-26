/* The request of the host to ztcl-enclave.dll (ztcl#180). The request
 * and each buffer it points to are in the memory of the host, and the
 * enclave reads and writes them only with EnclaveCopyIntoEnclave and
 * EnclaveCopyOutOfEnclave. See docs/dev/enclave.md.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef ZTCL_ENCLAVE_H
#define ZTCL_ENCLAVE_H

#include <stdint.h>

/* Run the script, then seal its output and make a report. */
#define ZTCL_ENCLAVE_RUN 0
/* Unseal `blob` into `out`. */
#define ZTCL_ENCLAVE_UNSEAL 1
/* Check `report` with EnclaveVerifyAttestationReport. */
#define ZTCL_ENCLAVE_VERIFY 2

/* The limits of the sizes that the enclave copies in. */
#define ZTCL_ENCLAVE_MAX_SCRIPT (1u << 20)
#define ZTCL_ENCLAVE_MAX_OUT (1u << 20)
#define ZTCL_ENCLAVE_MAX_BLOB (2u << 20)
#define ZTCL_ENCLAVE_MAX_REPORT (64u << 10)
#define ZTCL_ENCLAVE_NONCE 32

typedef struct ztcl_enclave_request {
    uint32_t mode;
    /* In: the script and its limits. */
    const char *script;
    uint32_t script_len;
    uint64_t compute_limit;
    uint64_t mem_limit;
    uint8_t nonce[ZTCL_ENCLAVE_NONCE];
    /* Out: the output, or the message of an error. */
    char *out;
    uint32_t out_cap;
    uint32_t out_len;
    /* 0, 1 for an error of the script, 2 for a full output, or an
     * HRESULT of Windows below 0. */
    int32_t code;
    /* Out in a run, in in an unseal. */
    uint8_t *blob;
    uint32_t blob_cap;
    uint32_t blob_len;
    /* Out in a run, in in a check: the attestation report. */
    uint8_t *report;
    uint32_t report_cap;
    uint32_t report_len;
} ztcl_enclave_request;

#endif
