/* The test package of commands, scripts, results, and variables:
 * the slots of src/cext/host.zig.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdio.h>
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

/* The shape of a value: a list object gives L(...) of its elements, and
 * other values give their text. Only the kind of the object shows that
 * a list stays a list across the bridge. */
static void Describe(Tcl_Obj *out, Tcl_Obj *o) {
    int n, i;
    Tcl_Obj **items;
    if (o->typePtr != NULL && strcmp(o->typePtr->name, "list") == 0) {
        Tcl_ListObjGetElements(NULL, o, &n, &items);
        Tcl_AppendToObj(out, "L(", -1);
        for (i = 0; i < n; i++) {
            if (i > 0) Tcl_AppendToObj(out, " ", -1);
            Describe(out, items[i]);
        }
        Tcl_AppendToObj(out, ")", -1);
        return;
    }
    Tcl_AppendObjToObj(out, o);
}

static int Shape(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_Obj *out = Tcl_NewObj();
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "value");
        return TCL_ERROR;
    }
    Describe(out, objv[1]);
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

/* The list {a {b c} 7 x\0y}, with an inner list and an int. */
static Tcl_Obj *MakeList(void) {
    Tcl_Obj *inner[2], *items[4];
    inner[0] = Tcl_NewStringObj("b", -1);
    inner[1] = Tcl_NewStringObj("c", -1);
    items[0] = Tcl_NewStringObj("a", -1);
    items[1] = Tcl_NewListObj(2, inner);
    items[2] = Tcl_NewWideIntObj(7);
    items[3] = Tcl_NewStringObj("x\xc0\x80y", 4);
    return Tcl_NewListObj(4, items);
}

static int MkList(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd; (void)objc; (void)objv;
    Tcl_SetObjResult(interp, MakeList());
    return TCL_OK;
}

/* Sets ::cxl to the list of MakeList and gives the shape of the value
 * that comes back from the variable. */
static int VarList(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_Obj *v, *out = Tcl_NewObj();
    (void)cd; (void)objc; (void)objv;
    if (Tcl_SetVar2Ex(interp, "::cxl", NULL, MakeList(), TCL_LEAVE_ERR_MSG) == NULL) return TCL_ERROR;
    v = Tcl_GetVar2Ex(interp, "::cxl", NULL, TCL_LEAVE_ERR_MSG);
    if (v == NULL) return TCL_ERROR;
    Describe(out, v);
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

/* Gives the shape of the result of a script. */
static int EvalShape(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_Obj *out = Tcl_NewObj();
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "script");
        return TCL_ERROR;
    }
    if (Tcl_EvalObjEx(interp, objv[1], 0) != TCL_OK) return TCL_ERROR;
    Describe(out, Tcl_GetObjResult(interp));
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

/* Gives the bytes of the text of a value in hex, and its length in
 * characters. */
static int Bytes(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int n, i;
    const unsigned char *s;
    char hex[8];
    Tcl_Obj *out = Tcl_NewObj();
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "value");
        return TCL_ERROR;
    }
    s = (const unsigned char *)Tcl_GetStringFromObj(objv[1], &n);
    for (i = 0; i < n; i++) {
        sprintf(hex, i > 0 ? " %02x" : "%02x", s[i]);
        Tcl_AppendToObj(out, hex, -1);
    }
    sprintf(hex, ":%d", Tcl_GetCharLength(objv[1]));
    Tcl_AppendToObj(out, hex, -1);
    Tcl_SetObjResult(interp, out);
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
    Tcl_CreateObjCommand(interp, "cxcmd::shape", Shape, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::mklist", MkList, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::varlist", VarList, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::evalshape", EvalShape, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxcmd::bytes", Bytes, NULL, NULL);
    return Tcl_PkgProvideEx(interp, "cxcmd", "1.0", NULL);
}
