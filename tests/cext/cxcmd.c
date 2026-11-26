/* The test package of commands, scripts, results, and variables:
 * the slots of src/cext/host.zig.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <string.h>
#include <tcl.h>

static int deleted;

static int Add(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_WideInt sum = 0, w;
    int i;
    (void)cd;
    for (i = 1; i < objc; i++) {
        if (Tcl_GetWideIntFromObj(interp, objv[i], &w) != TCL_OK) return TCL_ERROR;
        sum += w;
    }
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(sum));
    return TCL_OK;
}

static int Run(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int code;
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "script");
        return TCL_ERROR;
    }
    code = Tcl_EvalObjEx(interp, objv[1], 0);
    if (code == TCL_ERROR) Tcl_AppendResult(interp, " (in cxcmd::run)", NULL);
    return code;
}

static int Vars(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_Obj *v;
    (void)cd; (void)objc; (void)objv;
    v = Tcl_GetVar2Ex(interp, "cxin", NULL, TCL_LEAVE_ERR_MSG);
    if (v == NULL) return TCL_ERROR;
    Tcl_ObjSetVar2(interp, Tcl_NewStringObj("cxout", -1), NULL, Tcl_NewStringObj(Tcl_GetString(v), -1), 0);
    Tcl_SetVar(interp, "cxtext", "set by Tcl_SetVar", 0);
    Tcl_SetResult(interp, (char *)Tcl_GetVar(interp, "cxtext", 0), TCL_VOLATILE);
    return TCL_OK;
}

static int Glob(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd; (void)objc; (void)objv;
    if (Tcl_GlobalEval(interp, "set ::cxg global") != TCL_OK) return TCL_ERROR;
    return Tcl_VarEval(interp, "string toupper ", "$::cxg", NULL);
}

static int After(ClientData data[], Tcl_Interp *interp, int result) {
    Tcl_Obj *r = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    Tcl_AppendToObj(r, (const char *)data[0], -1);
    Tcl_SetObjResult(interp, r);
    return result;
}

static int Nre(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "script");
        return TCL_ERROR;
    }
    Tcl_NRAddCallback(interp, After, (ClientData)" +callback", NULL, NULL, NULL);
    return Tcl_NREvalObj(interp, objv[1], 0);
}

static void Gone(ClientData cd) { (void)cd; deleted++; }

static int Count(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd; (void)objc; (void)objv;
    Tcl_SetObjResult(interp, Tcl_NewIntObj(deleted));
    return TCL_OK;
}

static int Drop(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "name");
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_DeleteCommand(interp, Tcl_GetString(objv[1]))));
    return TCL_OK;
}

int Cxcmd_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxcmd::add", Add, NULL, Gone);
    Tcl_CreateObjCommand(interp, "cxcmd::run", Run, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::vars", Vars, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::glob", Glob, NULL, NULL);
    Tcl_NRCreateCommand(interp, "cxcmd::nre", Nre, Nre, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::count", Count, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::drop", Drop, NULL, NULL);
    return Tcl_PkgProvideEx(interp, "cxcmd", "1.0", NULL);
}
