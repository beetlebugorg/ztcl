/* The test package of the area scripts and results. The command
 * cxscript::run NAME ARG runs one check and gives its result.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdarg.h>
#include <string.h>
#include <tcl.h>

static int VarEval(Tcl_Interp *interp, ...) {
    va_list ap; int code;
    va_start(ap, interp);
    code = Tcl_VarEvalVA(interp, ap);
    va_end(ap);
    return code;
}

static void Append(Tcl_Interp *interp, ...) {
    va_list ap;
    va_start(ap, interp);
    Tcl_AppendResultVA(interp, ap);
    va_end(ap);
}

static int Run(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *n, *a;
    long l; double d; int b, code;
    Tcl_Obj *o;
    (void)cd;
    if (objc != 3) { Tcl_WrongNumArgs(interp, 1, objv, "name arg"); return TCL_ERROR; }
    n = Tcl_GetString(objv[1]);
    a = Tcl_GetString(objv[2]);
    if (!strcmp(n, "exprlong")) {
        code = Tcl_ExprLong(interp, a, &l);
        if (code == TCL_OK) Tcl_SetObjResult(interp, Tcl_NewLongObj(l));
        return code;
    }
    if (!strcmp(n, "exprdouble")) {
        code = Tcl_ExprDoubleObj(interp, objv[2], &d);
        if (code == TCL_OK) Tcl_SetObjResult(interp, Tcl_NewDoubleObj(d));
        return code;
    }
    if (!strcmp(n, "exprboolean")) {
        code = Tcl_ExprBoolean(interp, a, &b);
        if (code == TCL_OK) Tcl_SetObjResult(interp, Tcl_NewIntObj(b));
        return code;
    }
    if (!strcmp(n, "exprobj")) {
        code = Tcl_ExprObj(interp, objv[2], &o);
        if (code != TCL_OK) return code;
        Tcl_SetObjResult(interp, o);
        Tcl_DecrRefCount(o);
        return TCL_OK;
    }
    if (!strcmp(n, "exprstring")) return Tcl_ExprString(interp, a);
    if (!strcmp(n, "evalobjv")) {
        Tcl_Obj **v; int c;
        if (Tcl_ListObjGetElements(interp, objv[2], &c, &v) != TCL_OK) return TCL_ERROR;
        return Tcl_EvalObjv(interp, c, v, 0);
    }
    if (!strcmp(n, "globalevalobj")) return Tcl_GlobalEvalObj(interp, objv[2]);
    if (!strcmp(n, "evalobj")) return Tcl_EvalObj(interp, objv[2]);
    if (!strcmp(n, "vareval")) return VarEval(interp, "string ", "length ", a, NULL);
    if (!strcmp(n, "append")) { Tcl_SetResult(interp, "x", TCL_STATIC); Append(interp, "-", a, "-", NULL); return TCL_OK; }
    if (!strcmp(n, "subst")) {
        int flags = 0; Tcl_Obj **v; int c;
        if (Tcl_ListObjGetElements(interp, objv[2], &c, &v) != TCL_OK || c != 2) return TCL_ERROR;
        Tcl_GetIntFromObj(interp, v[0], &flags);
        o = Tcl_SubstObj(interp, v[1], flags);
        if (o == NULL) return TCL_ERROR;
        Tcl_SetObjResult(interp, o);
        return TCL_OK;
    }
    if (!strcmp(n, "complete")) { Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_CommandComplete(a))); return TCL_OK; }
    if (!strcmp(n, "saveresult")) {
        Tcl_SavedResult s;
        Tcl_SetObjResult(interp, Tcl_NewStringObj("kept", -1));
        Tcl_SaveResult(interp, &s);
        Tcl_Eval(interp, "set x lost");
        Tcl_RestoreResult(interp, &s);
        return TCL_OK;
    }
    if (!strcmp(n, "interpstate")) {
        Tcl_InterpState st;
        Tcl_Eval(interp, "error first");
        st = Tcl_SaveInterpState(interp, TCL_ERROR);
        Tcl_Eval(interp, "set y second");
        return Tcl_RestoreInterpState(interp, st);
    }
    if (!strcmp(n, "recordandeval")) return Tcl_RecordAndEval(interp, a, 0);
    if (!strcmp(n, "freeresult")) { Tcl_SetResult(interp, "gone", TCL_STATIC); Tcl_FreeResult(interp); return TCL_OK; }
    if (!strcmp(n, "cancel")) {
        int unwind = !strcmp(a, "unwind");
        code = Tcl_CancelEval(interp, !strcmp(a, "-") || unwind ? NULL : objv[2], NULL, unwind ? TCL_CANCEL_UNWIND : 0);
        if (code != TCL_OK) return code;
        code = Tcl_Canceled(interp, TCL_LEAVE_ERR_MSG | (unwind ? TCL_CANCEL_UNWIND : 0));
        return code == TCL_ERROR ? TCL_ERROR : TCL_OK;
    }
    if (!strcmp(n, "canceled")) { Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_Canceled(interp, 0))); return TCL_OK; }
    Tcl_SetResult(interp, "unknown check", TCL_STATIC);
    return TCL_ERROR;
}

int Cxscript_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxscript::run", Run, NULL, NULL);
    return TCL_OK;
}
