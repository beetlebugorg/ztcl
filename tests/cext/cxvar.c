/* The test package of the area variables: unset, upvar, traces, and
 * linked variables. The commands of the package run from cxvar.tcl.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <string.h>
#include <tcl.h>

static Tcl_Obj *log_;
static int ival = 5, bval = 1, roval = 7;
static double dval = 1.5;
static char *sval = NULL;
static Tcl_WideInt wval = 1;
static short shval = 3;

static char *Tracer(ClientData cd, Tcl_Interp *interp, const char *n1, const char *n2, int flags) {
    const char *tag = cd;
    (void)interp;
    Tcl_AppendPrintfToObj(log_, "%s:%s(%s):%s%s%s%s%s ", tag, n1, n2 ? n2 : "",
        flags & TCL_TRACE_READS ? "r" : "", flags & TCL_TRACE_WRITES ? "w" : "",
        flags & TCL_TRACE_UNSETS ? "u" : "", flags & TCL_TRACE_DESTROYED ? "D" : "",
        flags & TCL_GLOBAL_ONLY ? "G" : "");
    if (!strcmp(tag, "deny") && (flags & TCL_TRACE_WRITES)) return "no writes here";
    return NULL;
}

/* cxvar cmd ?arg ...? */
static int VarCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *op;
    int rc = TCL_OK;
    (void)cd;
    if (objc < 2) return TCL_ERROR;
    op = Tcl_GetString(objv[1]);
    if (!strcmp(op, "unset") && objc >= 3) {
        rc = Tcl_UnsetVar(interp, Tcl_GetString(objv[2]), objc > 3 ? TCL_LEAVE_ERR_MSG : 0);
        if (rc != TCL_OK && objc == 3) Tcl_SetObjResult(interp, Tcl_ObjPrintf("rc %d, result <%s>", rc, Tcl_GetStringResult(interp)));
        else if (rc == TCL_OK) Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
        return objc > 3 ? rc : TCL_OK;
    }
    if (!strcmp(op, "unset2")) {
        rc = Tcl_UnsetVar2(interp, Tcl_GetString(objv[2]), Tcl_GetString(objv[3]), TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG);
        return rc;
    }
    if (!strcmp(op, "upvar")) {
        return Tcl_UpVar(interp, Tcl_GetString(objv[2]), Tcl_GetString(objv[3]), Tcl_GetString(objv[4]), 0);
    }
    if (!strcmp(op, "upvar2")) {
        return Tcl_UpVar2(interp, "1", Tcl_GetString(objv[2]), Tcl_GetString(objv[3]), Tcl_GetString(objv[4]), 0);
    }
    if (!strcmp(op, "trace")) {
        int flags = 0;
        const char *f = Tcl_GetString(objv[3]);
        if (strchr(f, 'r')) flags |= TCL_TRACE_READS;
        if (strchr(f, 'w')) flags |= TCL_TRACE_WRITES;
        if (strchr(f, 'u')) flags |= TCL_TRACE_UNSETS;
        if (strchr(f, 'g')) flags |= TCL_GLOBAL_ONLY;
        if (objc > 5)
            return Tcl_TraceVar2(interp, Tcl_GetString(objv[2]), Tcl_GetString(objv[5]), flags, Tracer, (ClientData)strdup(Tcl_GetString(objv[4])));
        return Tcl_TraceVar(interp, Tcl_GetString(objv[2]), flags | TCL_LEAVE_ERR_MSG, Tracer, (ClientData)strdup(Tcl_GetString(objv[4])));
    }
    if (!strcmp(op, "untrace")) {
        /* Removes each trace of Tracer on the variable, with any tag. */
        ClientData c;
        int n = 0;
        const char *name = Tcl_GetString(objv[2]);
        int flags = TCL_TRACE_READS | TCL_TRACE_WRITES | TCL_TRACE_UNSETS;
        if (objc > 3) flags = TCL_TRACE_WRITES;
        while ((c = Tcl_VarTraceInfo(interp, name, 0, Tracer, NULL)) != NULL && n < 10) {
            Tcl_AppendPrintfToObj(log_, "info:%s ", (char *)c);
            Tcl_UntraceVar(interp, name, flags, Tracer, c);
            n++;
            if (objc > 3) break;
        }
        return TCL_OK;
    }
    if (!strcmp(op, "info")) {
        ClientData c = NULL;
        Tcl_Obj *o = Tcl_NewObj();
        while ((c = Tcl_VarTraceInfo(interp, Tcl_GetString(objv[2]), 0, Tracer, c)) != NULL)
            Tcl_AppendPrintfToObj(o, "%s ", (char *)c);
        Tcl_SetObjResult(interp, o);
        return TCL_OK;
    }
    if (!strcmp(op, "log")) {
        Tcl_SetObjResult(interp, log_);
        log_ = Tcl_NewObj();
        Tcl_IncrRefCount(log_);
        return TCL_OK;
    }
    if (!strcmp(op, "link")) {
        rc = Tcl_LinkVar(interp, "lint", (char *)&ival, TCL_LINK_INT);
        rc |= Tcl_LinkVar(interp, "ldouble", (char *)&dval, TCL_LINK_DOUBLE);
        rc |= Tcl_LinkVar(interp, "lbool", (char *)&bval, TCL_LINK_BOOLEAN);
        rc |= Tcl_LinkVar(interp, "lstr", (char *)&sval, TCL_LINK_STRING);
        rc |= Tcl_LinkVar(interp, "lwide", (char *)&wval, TCL_LINK_WIDE_INT);
        rc |= Tcl_LinkVar(interp, "lshort", (char *)&shval, TCL_LINK_SHORT);
        rc |= Tcl_LinkVar(interp, "lro", (char *)&roval, TCL_LINK_INT | TCL_LINK_READ_ONLY);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
        return TCL_OK;
    }
    if (!strcmp(op, "cvals")) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %g %d %s %lld %d %d", ival, dval, bval, sval ? sval : "NULL", (long long)wval, shval, roval));
        return TCL_OK;
    }
    if (!strcmp(op, "bump")) {
        ival += 10;
        roval += 1;
        Tcl_UpdateLinkedVar(interp, "lro");
        return TCL_OK;
    }
    if (!strcmp(op, "unlink")) {
        Tcl_UnlinkVar(interp, "lint");
        ival = 99;
        return TCL_OK;
    }
    return TCL_ERROR;
}

int Cxvar_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    log_ = Tcl_NewObj();
    Tcl_IncrRefCount(log_);
    Tcl_CreateObjCommand(interp, "cxvar", VarCmd, NULL, NULL);
    return TCL_OK;
}
