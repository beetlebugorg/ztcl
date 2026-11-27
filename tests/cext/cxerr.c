/* The test package of the error slots (src/cext/errors.zig): the error
 * code, the error info, the return options, errno names, the error code
 * of Tcl_ParseExpr, and background errors. Each op of the command
 * `cxerr` sets a part of the error state.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <errno.h>
#include <string.h>
#include <tcl.h>

/* The value of key `k` of the dictionary `d`, or NULL. */
static Tcl_Obj *Get(Tcl_Obj *d, const char *k) {
    int n, i;
    Tcl_Obj **v;
    if (Tcl_ListObjGetElements(NULL, d, &n, &v) != TCL_OK) return NULL;
    for (i = 0; i + 1 < n; i += 2) {
        if (strcmp(Tcl_GetString(v[i]), k) == 0) return v[i + 1];
    }
    return NULL;
}

static void Append(Tcl_Obj *l, Tcl_Obj *v) {
    Tcl_ListObjAppendElement(NULL, l, v ? v : Tcl_NewStringObj("-", -1));
}

static int Cxerr(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *op;
    (void)cd;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "op ?arg ...?");
        return TCL_ERROR;
    }
    op = Tcl_GetString(objv[1]);
    if (strcmp(op, "code") == 0 && objc == 4) {
        /* An error with a message and an error code. */
        Tcl_SetObjResult(interp, objv[2]);
        Tcl_SetObjErrorCode(interp, objv[3]);
        return TCL_ERROR;
    }
    if (strcmp(op, "codes") == 0) {
        Tcl_SetResult(interp, "varargs", TCL_STATIC);
        Tcl_SetErrorCode(interp, "CX", "TWO", "words", NULL);
        return TCL_ERROR;
    }
    if (strcmp(op, "info") == 0 && objc == 4) {
        Tcl_SetObjResult(interp, objv[2]);
        Tcl_AddErrorInfo(interp, Tcl_GetString(objv[3]));
        Tcl_AppendObjToErrorInfo(interp, Tcl_NewStringObj(" and more", -1));
        return TCL_ERROR;
    }
    if (strcmp(op, "eval") == 0 && objc == 3) {
        int code = Tcl_EvalObjEx(interp, objv[2], 0);
        if (code == TCL_ERROR) Tcl_AddErrorInfo(interp, "\n    (in cxerr eval)");
        return code;
    }
    if (strcmp(op, "reset") == 0 && objc == 3) {
        /* A new error after a failed script: the old error info goes. */
        Tcl_EvalObjEx(interp, objv[2], 0);
        Tcl_ResetResult(interp);
        Tcl_SetResult(interp, "fresh", TCL_STATIC);
        return TCL_ERROR;
    }
    if (strcmp(op, "opts") == 0 && objc == 3) {
        int code = Tcl_EvalObjEx(interp, objv[2], 0);
        Tcl_Obj *o = Tcl_GetReturnOptions(interp, code), *l = Tcl_NewListObj(0, NULL), *info;
        Tcl_IncrRefCount(o);
        Append(l, Get(o, "-code"));
        Append(l, Get(o, "-level"));
        Append(l, Get(o, "-errorcode"));
        info = Get(o, "-errorinfo");
        if (info) {
            const char *s = Tcl_GetString(info), *nl = strchr(s, '\n');
            info = Tcl_NewStringObj(s, nl ? (int)(nl - s) : -1);
        }
        Append(l, info);
        Append(l, Get(o, "-errorline"));
        Tcl_DecrRefCount(o);
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (strcmp(op, "setopts") == 0 && objc == 4) {
        Tcl_SetObjResult(interp, objv[3]);
        return Tcl_SetReturnOptions(interp, objv[2]);
    }
    if (strcmp(op, "posix") == 0) {
        const char *msg;
        Tcl_SetErrno(ENOENT);
        msg = Tcl_PosixError(interp);
        Tcl_Obj *o = Tcl_NewStringObj(Tcl_ErrnoId(), -1);
        Tcl_AppendStringsToObj(o, " ", msg, NULL);
        Tcl_SetObjResult(interp, o);
        return TCL_ERROR;
    }
    if (strcmp(op, "parseexpr") == 0 && objc == 3) {
        Tcl_Parse p;
        int n;
        const char *s = Tcl_GetStringFromObj(objv[2], &n);
        if (Tcl_ParseExpr(interp, s, n, &p) != TCL_OK) return TCL_ERROR;
        Tcl_FreeParse(&p);
        return TCL_OK;
    }
    if (strcmp(op, "logcmd") == 0) {
        static const char cmd[] = "a command of the package that is long enough to be cut by the log of the command info of Tcl at the limit of one hundred fifty bytes of text";
        Tcl_SetResult(interp, "logged", TCL_STATIC);
        Tcl_LogCommandInfo(interp, cmd, cmd, (int)strlen(cmd));
        Tcl_LogCommandInfo(interp, cmd, cmd, 9);
        return TCL_ERROR;
    }
    if (strcmp(op, "line") == 0 && objc == 3) {
        int n;
        if (Tcl_GetIntFromObj(interp, objv[2], &n) != TCL_OK) return TCL_ERROR;
        Tcl_SetErrorLine(interp, n);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_GetErrorLine(interp)));
        return TCL_OK;
    }
    if (strcmp(op, "bg") == 0 && objc == 3) {
        Tcl_SetObjResult(interp, objv[2]);
        Tcl_SetErrorCode(interp, "CX", "BG", NULL);
        Tcl_BackgroundException(interp, TCL_ERROR);
        Tcl_SetResult(interp, "queued", TCL_STATIC);
        return TCL_OK;
    }
    if (strcmp(op, "allow") == 0) {
        Tcl_AllowExceptions(interp);
        return TCL_OK;
    }
    Tcl_SetResult(interp, "bad op", TCL_STATIC);
    return TCL_ERROR;
}

int Cxerr_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxerr", Cxerr, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxerr", "1.0");
}
