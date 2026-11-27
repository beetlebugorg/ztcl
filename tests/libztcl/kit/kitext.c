/*
 * A small extension for tools/libztcl/kit.sh. It is built with
 * -DUSE_TCL_STUBS and the stub library of the kit of libztcl, as a TEA
 * extension is, and it loads in Tcl, in libztcl, and in the ztcl runner.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <tcl.h>

static int
SumCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_WideInt sum = 0, v;
    int i;

    (void) cd;
    for (i = 1; i < objc; i++) {
        if (Tcl_GetWideIntFromObj(interp, objv[i], &v) != TCL_OK) {
            return TCL_ERROR;
        }
        sum += v;
    }
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(sum));
    return TCL_OK;
}

static int
JoinCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_DString ds;
    int i;

    (void) cd;
    Tcl_DStringInit(&ds);
    for (i = 1; i < objc; i++) {
        Tcl_DStringAppendElement(&ds, Tcl_GetString(objv[i]));
    }
    Tcl_DStringResult(interp, &ds);
    return TCL_OK;
}

DLLEXPORT int
Kitext_Init(Tcl_Interp *interp)
{
    const char *v = Tcl_InitStubs(interp, "8.6", 0);

    if (v == NULL) {
        return TCL_ERROR;
    }
    if (Tcl_SetVar(interp, "kitext_stubs", v, TCL_GLOBAL_ONLY|TCL_LEAVE_ERR_MSG) == NULL) {
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "kitext_sum", SumCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "kitext_join", JoinCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "kitext", "1.0");
}
