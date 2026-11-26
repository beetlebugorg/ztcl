/* The test package of Tcl_SetPanicProc and Tcl_Panic. The panic proc
 * writes the message to the standard output and ends the process with
 * status 0, so the output of tclsh and of ztcl can be compared.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdio.h>
#include <stdlib.h>
#include <tcl.h>

static void Proc(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("panic: ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    exit(0);
}

int Cxpanic_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    printf("init\n");
    fflush(stdout);
    Tcl_SetPanicProc(Proc);
    Tcl_Panic("%s %d %s", "code", 42, "end");
    return TCL_OK;
}
