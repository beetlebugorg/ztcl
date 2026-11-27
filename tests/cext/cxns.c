/* The test package of the area namespaces: namespaces, exports and
 * imports, the unknown handler, and ensembles. The commands of the
 * package run from cxns.tcl.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <string.h>
#include <tcl.h>

static Tcl_Obj *log_;

static void NsGone(ClientData cd) {
    Tcl_AppendPrintfToObj(log_, "gone:%s ", (const char *)cd);
}

static const char *Full(Tcl_Namespace *ns) {
    return ns ? ns->fullName : "NULL";
}

static Tcl_Namespace *Ns(Tcl_Interp *interp, Tcl_Obj *o) {
    const char *n = Tcl_GetString(o);
    return strcmp(n, "-") ? Tcl_FindNamespace(interp, n, NULL, 0) : NULL;
}

static int Show(Tcl_Interp *interp, int rc, Tcl_Obj *o) {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %s", rc, rc != TCL_OK ? Tcl_GetStringResult(interp) : o ? Tcl_GetString(o) : "NULL"));
    return TCL_OK;
}

/* cxns cmd ?arg ...? */
static int NsCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *op;
    (void)cd;
    if (objc < 2) return TCL_ERROR;
    op = Tcl_GetString(objv[1]);
    if (!strcmp(op, "log")) {
        Tcl_SetObjResult(interp, log_);
        Tcl_DecrRefCount(log_);
        log_ = Tcl_NewObj();
        Tcl_IncrRefCount(log_);
        return TCL_OK;
    }
    if (!strcmp(op, "create") && objc == 3) {
        Tcl_Namespace *ns = Tcl_CreateNamespace(interp, Tcl_GetString(objv[2]), "c", NsGone);
        if (!ns) return Show(interp, TCL_ERROR, NULL);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s %s parent %s data %s", ns->name, ns->fullName, Full(ns->parentPtr), (char *)ns->clientData));
        return TCL_OK;
    }
    if (!strcmp(op, "delete") && objc == 3) {
        Tcl_Namespace *ns = Ns(interp, objv[2]);
        if (ns) Tcl_DeleteNamespace(ns);
        return TCL_OK;
    }
    if (!strcmp(op, "find") && objc >= 3) {
        Tcl_Namespace *ctx = objc > 3 ? Ns(interp, objv[3]) : NULL;
        int flags = objc > 4 ? TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG : TCL_LEAVE_ERR_MSG;
        Tcl_Namespace *ns = Tcl_FindNamespace(interp, Tcl_GetString(objv[2]), ctx, flags);
        if (!ns) return Show(interp, TCL_ERROR, NULL);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s same %d", ns->fullName, ns == Tcl_FindNamespace(interp, ns->fullName, NULL, 0)));
        return TCL_OK;
    }
    if (!strcmp(op, "current")) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s %s", Full(Tcl_GetCurrentNamespace(interp)), Full(Tcl_GetGlobalNamespace(interp))));
        return TCL_OK;
    }
    if (!strcmp(op, "export") && objc == 5) {
        int rc = Tcl_Export(interp, Ns(interp, objv[2]), Tcl_GetString(objv[3]), !strcmp(Tcl_GetString(objv[4]), "reset"));
        Tcl_Obj *l = Tcl_NewObj();
        if (rc == TCL_OK) rc = Tcl_AppendExportList(interp, Ns(interp, objv[2]), l);
        return Show(interp, rc, l);
    }
    if (!strcmp(op, "import") && objc == 5) {
        int rc = Tcl_Import(interp, Ns(interp, objv[2]), Tcl_GetString(objv[3]), !strcmp(Tcl_GetString(objv[4]), "force"));
        return Show(interp, rc, Tcl_NewObj());
    }
    if (!strcmp(op, "forget") && objc == 4) {
        return Show(interp, Tcl_ForgetImport(interp, Ns(interp, objv[2]), Tcl_GetString(objv[3])), Tcl_NewObj());
    }
    if (!strcmp(op, "unknown") && objc >= 3) {
        Tcl_Namespace *ns = Ns(interp, objv[2]);
        int rc = TCL_OK;
        if (objc > 3) rc = Tcl_SetNamespaceUnknownHandler(interp, ns, objv[3]);
        return Show(interp, rc, rc == TCL_OK ? Tcl_GetNamespaceUnknownHandler(interp, ns) : NULL);
    }
    if (!strcmp(op, "ensemble") && objc == 4) {
        Tcl_Command c = Tcl_CreateEnsemble(interp, Tcl_GetString(objv[2]), Ns(interp, objv[3]), TCL_ENSEMBLE_PREFIX);
        Tcl_Obj *full = Tcl_NewObj();
        if (!c) return Show(interp, TCL_ERROR, NULL);
        Tcl_GetCommandFullName(interp, c, full);
        return Show(interp, TCL_OK, full);
    }
    if (!strcmp(op, "isens") && objc == 3) {
        Tcl_Command c = Tcl_FindEnsemble(interp, objv[2], TCL_LEAVE_ERR_MSG);
        if (!c) return Show(interp, TCL_ERROR, NULL);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_IsEnsemble(c)));
        return TCL_OK;
    }
    if (!strcmp(op, "ensset") && objc == 5) {
        Tcl_Command c = Tcl_FindEnsemble(interp, objv[2], 0);
        const char *w = Tcl_GetString(objv[3]);
        int rc;
        if (!c) return Show(interp, TCL_ERROR, NULL);
        if (!strcmp(w, "map")) rc = Tcl_SetEnsembleMappingDict(interp, c, objv[4]);
        else if (!strcmp(w, "subcommands")) rc = Tcl_SetEnsembleSubcommandList(interp, c, objv[4]);
        else if (!strcmp(w, "unknown")) rc = Tcl_SetEnsembleUnknownHandler(interp, c, objv[4]);
        else if (!strcmp(w, "parameters")) rc = Tcl_SetEnsembleParameterList(interp, c, objv[4]);
        else {
            int f;
            Tcl_GetIntFromObj(NULL, objv[4], &f);
            rc = Tcl_SetEnsembleFlags(interp, c, f);
        }
        return Show(interp, rc, Tcl_NewObj());
    }
    if (!strcmp(op, "ensget") && objc == 3) {
        Tcl_Command c = Tcl_FindEnsemble(interp, objv[2], 0);
        Tcl_Obj *m = NULL, *s = NULL, *u = NULL, *p = NULL;
        Tcl_Namespace *ns = NULL;
        int f = -1;
        if (!c) return Show(interp, TCL_ERROR, NULL);
        Tcl_GetEnsembleMappingDict(interp, c, &m);
        Tcl_GetEnsembleSubcommandList(interp, c, &s);
        Tcl_GetEnsembleUnknownHandler(interp, c, &u);
        Tcl_GetEnsembleParameterList(interp, c, &p);
        Tcl_GetEnsembleFlags(interp, c, &f);
        Tcl_GetEnsembleNamespace(interp, c, &ns);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("map <%s> sub <%s> unknown <%s> params <%s> flags %d ns %s",
            m ? Tcl_GetString(m) : "NULL", s ? Tcl_GetString(s) : "NULL", u ? Tcl_GetString(u) : "NULL",
            p ? Tcl_GetString(p) : "NULL", f & TCL_ENSEMBLE_PREFIX, Full(ns)));
        return TCL_OK;
    }
    if (!strcmp(op, "notens") && objc == 3) {
        Tcl_Command c = Tcl_FindCommand(interp, Tcl_GetString(objv[2]), NULL, 0);
        Tcl_Obj *m = NULL;
        int rc;
        if (!c) return TCL_ERROR;
        rc = Tcl_GetEnsembleMappingDict(interp, c, &m);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %d", Tcl_IsEnsemble(c), rc));
        return TCL_OK;
    }
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("bad op %s", op));
    return TCL_ERROR;
}

int Cxns_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    log_ = Tcl_NewObj();
    Tcl_IncrRefCount(log_);
    Tcl_CreateObjCommand(interp, "cxns", NsCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxns", "1.0");
}
