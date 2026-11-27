/*
 * A program that embeds Tcl, for tools/libztcl/kit.sh. It is built with
 * the flags of `pkg-config --cflags --libs tcl` of the kit of libztcl.
 *
 *   kitembed DIR SCRIPT    sets dir to DIR and runs SCRIPT
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <stdio.h>
#include <tcl.h>

int
main(int argc, char **argv)
{
    Tcl_Interp *interp;
    int code;

    if (argc != 3) {
        fprintf(stderr, "usage: kitembed DIR SCRIPT\n");
        return 2;
    }
    Tcl_FindExecutable(argv[0]);
    interp = Tcl_CreateInterp();
    if (Tcl_Init(interp) != TCL_OK) {
        fprintf(stderr, "Tcl_Init: %s\n", Tcl_GetStringResult(interp));
        return 1;
    }
    Tcl_SetVar(interp, "dir", argv[1], TCL_GLOBAL_ONLY);
    code = Tcl_EvalFile(interp, argv[2]);
    if (code != TCL_OK) {
        printf("error: %s\n", Tcl_GetStringResult(interp));
    }
    Tcl_DeleteInterp(interp);
    return code == TCL_OK ? 0 : 1;
}
