/*
 * A test program that embeds Tcl, for tools/libztcl/check.sh. It links
 * libtcl8.6 or libztcl and uses only the public API of tcl.h.
 *
 *   embed ?script? ?arg ...?   Tcl_Main with an init function
 *   embed -eval SCRIPT         an interp with no Tcl_Main
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <stdio.h>
#include <string.h>
#include <tcl.h>

/* sum ?int ...?: the sum of the arguments. */
static int
SumCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_WideInt total = 0;
    int i;
    (void)cd;
    for (i = 1; i < objc; i++) {
	Tcl_WideInt v;
	if (Tcl_GetWideIntFromObj(interp, objv[i], &v) != TCL_OK) {
	    return TCL_ERROR;
	}
	total += v;
    }
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(total));
    return TCL_OK;
}

/* rev list: the elements of the list in reverse order. */
static int
RevCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_Obj **elems, *out;
    int n, i;
    (void)cd;
    if (objc != 2) {
	Tcl_WrongNumArgs(interp, 1, objv, "list");
	return TCL_ERROR;
    }
    if (Tcl_ListObjGetElements(interp, objv[1], &n, &elems) != TCL_OK) {
	return TCL_ERROR;
    }
    out = Tcl_NewListObj(0, NULL);
    for (i = n - 1; i >= 0; i--) {
	Tcl_ListObjAppendElement(interp, out, elems[i]);
    }
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

static int
AppInit(Tcl_Interp *interp)
{
    if (Tcl_Init(interp) == TCL_ERROR) {
	return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "sum", SumCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "rev", RevCmd, NULL, NULL);
    Tcl_SetVar(interp, "embed", "main", TCL_GLOBAL_ONLY);
    return TCL_OK;
}

static int
EvalOnly(const char *script)
{
    Tcl_Interp *interp = Tcl_CreateInterp();
    Tcl_Obj *v;
    int code;

    AppInit(interp);
    Tcl_SetVar(interp, "embed", "eval", TCL_GLOBAL_ONLY);
    code = Tcl_Eval(interp, script);
    printf("code %d result {%s}\n", code, Tcl_GetStringResult(interp));
    if (code == TCL_ERROR) {
	printf("errorInfo {%s}\n", Tcl_GetVar(interp, "errorInfo", TCL_GLOBAL_ONLY));
    }
    v = Tcl_GetVar2Ex(interp, "out", NULL, TCL_GLOBAL_ONLY);
    if (v != NULL) {
	printf("out {%s}\n", Tcl_GetString(v));
    }
    Tcl_DeleteInterp(interp);
    return code;
}

int
main(int argc, char **argv)
{
    Tcl_FindExecutable(argv[0]);
    if (argc == 3 && strcmp(argv[1], "-eval") == 0) {
	return EvalOnly(argv[2]);
    }
    Tcl_Main(argc, argv, AppInit);
    return 0;
}
