/* The test package of the memory and package slots. Cxmem_Init runs
 * the checks. A failed check sets interp->result to its name and makes
 * the init fail.
 * SPDX-License-Identifier: BSD-2-Clause */
#define USE_INTERP_RESULT
#include <string.h>
#include <tcl.h>
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

static int freed[3];
static int order;

static void FreeOne(char *p) { freed[(int)(p - (char *)freed) / (int)sizeof(int) % 3] = ++order; }
static void Note(char *p) { (void)p; freed[0] = ++order; }

#define CHECK(c) do { if (!(c)) { interp->result = (char *)#c; return TCL_ERROR; } } while (0)

int Cxmem_Init(Tcl_Interp *interp) {
    ClientData cd = NULL;
    static int marker;
    int major, minor, patch, kind;
    char *p, *q;
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;

    p = Tcl_Alloc(16);
    CHECK(p != NULL);
    memcpy(p, "0123456789abcdef", 16);
    p = Tcl_Realloc(p, 100000);
    CHECK(memcmp(p, "0123456789abcdef", 16) == 0);
    Tcl_Free(p);
    q = Tcl_Alloc(0);
    CHECK(q != NULL);
    ckfree(q);
    p = attemptckalloc(32);
    CHECK(p != NULL);
    p = attemptckrealloc(p, 64);
    CHECK(p != NULL);
    ckfree(p);
    p = Tcl_DbCkalloc(8, __FILE__, __LINE__);
    p = Tcl_DbCkrealloc(p, 16, __FILE__, __LINE__);
    Tcl_DbCkfree(p, __FILE__, __LINE__);
    /* With no TCL_MEM_DEBUG, the header makes these two macros empty. */
    CHECK(tclStubsPtr->tcl_DumpActiveMemory(NULL) == TCL_OK);
    tclStubsPtr->tcl_ValidateAllMemory(__FILE__, __LINE__);

    /* Two counts: the free waits for the second Tcl_Release. */
    order = 0;
    Tcl_Preserve(&freed[0]);
    Tcl_Preserve(&freed[0]);
    Tcl_EventuallyFree(&freed[0], Note);
    CHECK(freed[0] == 0);
    Tcl_Release(&freed[0]);
    CHECK(freed[0] == 0);
    Tcl_Release(&freed[0]);
    CHECK(freed[0] == 1);
    /* No count: the free is at once. */
    Tcl_EventuallyFree(&freed[1], (Tcl_FreeProc *)FreeOne);
    CHECK(freed[1] == 2);
    /* With no Tcl_EventuallyFree, the last Tcl_Release does not free. */
    Tcl_Preserve(&freed[2]);
    Tcl_Release(&freed[2]);
    CHECK(freed[2] == 0);
    p = ckalloc(10);
    Tcl_EventuallyFree(p, TCL_DYNAMIC);

    Tcl_GetVersion(&major, &minor, &patch, &kind);
    CHECK(major == 8 && minor == 6 && kind == TCL_FINAL_RELEASE);
    CHECK(Tcl_PkgRequireEx(interp, "Tcl", "8.5", 0, &cd) != NULL);
    CHECK(cd == (ClientData)tclStubsPtr);
    CHECK(Tcl_PkgRequire(interp, "Tcl", "9.0", 0) == NULL);
    CHECK(Tcl_PkgRequire(interp, "Tcl", "8.5", 1) == NULL);
    CHECK(Tcl_PkgPresent(interp, "Tcl", NULL, 0) != NULL);
    CHECK(Tcl_PkgProvideEx(interp, "cxmem", "1.2", &marker) == TCL_OK);
    cd = NULL;
    CHECK(strcmp(Tcl_PkgPresentEx(interp, "cxmem", "1.0", 0, &cd), "1.2") == 0);
    CHECK(cd == &marker);
    CHECK(Tcl_PkgPresent(interp, "cxmem", "2.0", 0) == NULL);
    interp->result = (char *)"";
    return TCL_OK;
}
