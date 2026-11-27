/* The test package of the area interps and commands: command tokens,
 * command traces, math functions, child interps, aliases, hidden
 * commands, and limits. The commands of the package run from
 * cxinterp.tcl, and from cxchild.tcl through cxchild.c.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdlib.h>
#include <string.h>
#include <tcl.h>

static Tcl_Obj *log_;

static void CmdTracer(ClientData cd, Tcl_Interp *interp, const char *oldName, const char *newName, int flags) {
    (void)interp;
    Tcl_AppendPrintfToObj(log_, "%s:%s->%s:%s%s%s ", (const char *)cd, oldName ? oldName : "NULL",
        newName ? newName : "NULL", flags & TCL_TRACE_RENAME ? "R" : "", flags & TCL_TRACE_DELETE ? "D" : "",
        flags & TCL_TRACE_DESTROYED ? "X" : "");
}

static int Twice(ClientData cd, Tcl_Interp *interp, Tcl_Value *args, Tcl_Value *res) {
    (void)cd;
    if (args[0].type == TCL_INT && args[0].intValue == 13) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("unlucky", -1));
        return TCL_ERROR;
    }
    if (args[0].type == TCL_DOUBLE) {
        res->type = TCL_DOUBLE;
        res->doubleValue = args[0].doubleValue * 2;
    } else if (args[0].type == TCL_WIDE_INT) {
        res->type = TCL_WIDE_INT;
        res->wideValue = args[0].wideValue * 2;
    } else {
        res->type = TCL_INT;
        res->intValue = args[0].intValue * 2;
    }
    return TCL_OK;
}

static int Hyp(ClientData cd, Tcl_Interp *interp, Tcl_Value *args, Tcl_Value *res) {
    (void)cd;
    (void)interp;
    res->type = TCL_DOUBLE;
    res->doubleValue = args[0].doubleValue * args[0].doubleValue + args[1].doubleValue * args[1].doubleValue;
    return TCL_OK;
}

static int Kind(ClientData cd, Tcl_Interp *interp, Tcl_Value *args, Tcl_Value *res) {
    (void)cd;
    (void)interp;
    res->type = TCL_INT;
    res->intValue = args[0].type * 10 + args[1].type;
    return TCL_OK;
}

static void Gone(ClientData cd, Tcl_Interp *interp) {
    (void)interp;
    Tcl_AppendPrintfToObj(log_, "gone:%s ", (const char *)cd);
}

static void LimitHit(ClientData cd, Tcl_Interp *interp) {
    (void)interp;
    Tcl_AppendPrintfToObj(log_, "limit:%s ", (const char *)cd);
}

static void LimitFree(ClientData cd) {
    Tcl_AppendPrintfToObj(log_, "free:%s ", (const char *)cd);
}

static int Ok(Tcl_Interp *interp, int rc) {
    if (rc != TCL_OK) Tcl_SetObjResult(interp, Tcl_ObjPrintf("rc %d: %s", rc, Tcl_GetStringResult(interp)));
    return TCL_OK;
}

static Tcl_Interp *Child(Tcl_Interp *interp, Tcl_Obj *path) {
    Tcl_Interp *c = interp;
    int n, i;
    Tcl_Obj **elems;
    if (Tcl_ListObjGetElements(interp, path, &n, &elems) != TCL_OK) return NULL;
    for (i = 0; i < n && c; i++) c = Tcl_GetSlave(c, Tcl_GetString(elems[i]));
    return c;
}

/* cxinterp cmd ?arg ...? */
static int InterpCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
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
    if (!strcmp(op, "find") && objc >= 3) {
        int flags = objc > 3 ? atoi(Tcl_GetString(objv[3])) : 0;
        Tcl_Command c = Tcl_FindCommand(interp, Tcl_GetString(objv[2]), NULL, flags);
        Tcl_Obj *full;
        if (!c) return Ok(interp, (flags & TCL_LEAVE_ERR_MSG) ? TCL_ERROR : TCL_OK);
        full = Tcl_NewObj();
        Tcl_GetCommandFullName(interp, c, full);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s %s %d", Tcl_GetCommandName(interp, c), Tcl_GetString(full),
            c == Tcl_GetCommandFromObj(interp, objv[2])));
        Tcl_DecrRefCount(full);
        return TCL_OK;
    }
    if (!strcmp(op, "fromobj") && objc == 3) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_GetCommandFromObj(interp, objv[2]) != NULL));
        return TCL_OK;
    }
    if (!strcmp(op, "trace") && objc == 4) {
        return Ok(interp, Tcl_TraceCommand(interp, Tcl_GetString(objv[2]), TCL_TRACE_RENAME | TCL_TRACE_DELETE, CmdTracer, (ClientData)(strcmp(Tcl_GetString(objv[3]), "a") ? "b" : "a")));
    }
    if (!strcmp(op, "untrace") && objc == 4) {
        Tcl_UntraceCommand(interp, Tcl_GetString(objv[2]), TCL_TRACE_RENAME | TCL_TRACE_DELETE, CmdTracer, (ClientData)(strcmp(Tcl_GetString(objv[3]), "a") ? "b" : "a"));
        return TCL_OK;
    }
    if (!strcmp(op, "traceinfo") && objc == 3) {
        ClientData p = NULL;
        Tcl_Obj *out = Tcl_NewObj();
        while ((p = Tcl_CommandTraceInfo(interp, Tcl_GetString(objv[2]), 0, CmdTracer, p)) != NULL)
            Tcl_ListObjAppendElement(NULL, out, Tcl_NewStringObj(p, -1));
        Tcl_SetObjResult(interp, out);
        return TCL_OK;
    }
    if (!strcmp(op, "mathfuncs")) {
        static Tcl_ValueType one[] = {TCL_EITHER};
        static Tcl_ValueType two[] = {TCL_DOUBLE, TCL_DOUBLE};
        static Tcl_ValueType kinds[] = {TCL_INT, TCL_WIDE_INT};
        Tcl_CreateMathFunc(interp, "twice", 1, one, Twice, NULL);
        Tcl_CreateMathFunc(interp, "hyp", 2, two, Hyp, NULL);
        Tcl_CreateMathFunc(interp, "kind", 2, kinds, Kind, NULL);
        return TCL_OK;
    }
    if (!strcmp(op, "mathinfo") && objc == 3) {
        int n = 0;
        Tcl_ValueType *types = NULL;
        Tcl_MathProc *proc = NULL;
        ClientData d = NULL;
        int rc = Tcl_GetMathFuncInfo(interp, Tcl_GetString(objv[2]), &n, &types, &proc, &d);
        if (rc != TCL_OK) return Ok(interp, rc);
        /* Tcl 8.6.16 gives no count and no types for a function of
         * Tcl_CreateMathFunc. */
        if (proc != NULL) Tcl_SetObjResult(interp, Tcl_NewStringObj("c", -1));
        else Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %s %s", n, types ? "types" : "NULL", d ? "data" : "NULL"));
        return TCL_OK;
    }
    if (!strcmp(op, "mathlist") && objc == 3) {
        Tcl_Obj *l = Tcl_ListMathFuncs(interp, Tcl_GetString(objv[2]));
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (!strcmp(op, "putenv") && objc == 3) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_PutEnv(Tcl_GetString(objv[2]))));
        return TCL_OK;
    }
    if (!strcmp(op, "getenv") && objc == 3) {
        const char *v = getenv(Tcl_GetString(objv[2]));
        Tcl_SetObjResult(interp, Tcl_NewStringObj(v ? v : "NULL", -1));
        return TCL_OK;
    }
    if (!strcmp(op, "hostname")) {
        const char *h = Tcl_GetHostName();
        Tcl_SetObjResult(interp, Tcl_NewIntObj(h != NULL && h[0] != 0));
        return TCL_OK;
    }
    if (!strcmp(op, "proc")) {
        return Tcl_ProcObjCmd(NULL, interp, objc - 1, objv + 1);
    }
    if (!strcmp(op, "child") && objc == 4) {
        Tcl_Interp *c = Tcl_CreateSlave(interp, Tcl_GetString(objv[2]), atoi(Tcl_GetString(objv[3])));
        if (!c) return Ok(interp, TCL_ERROR);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_GetMaster(c) == interp && Child(interp, objv[2]) == c));
        return TCL_OK;
    }
    if (!strcmp(op, "getchild") && objc == 3) {
        Tcl_Interp *c = Child(interp, objv[2]);
        if (!c) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("none", -1));
            return TCL_OK;
        }
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("safe %d", Tcl_IsSafe(c)));
        return TCL_OK;
    }
    if (!strcmp(op, "path") && objc == 4) {
        Tcl_Interp *a = Child(interp, objv[2]), *b = Child(interp, objv[3]);
        int rc;
        if (!a || !b) return TCL_ERROR;
        rc = Tcl_GetInterpPath(a, b);
        if (a != interp) Tcl_SetObjResult(interp, Tcl_GetObjResult(a));
        return Ok(interp, rc);
    }
    if (!strcmp(op, "master") && objc == 3) {
        Tcl_Interp *c = Child(interp, objv[2]);
        Tcl_Interp *m = c ? Tcl_GetMaster(c) : NULL;
        Tcl_SetObjResult(interp, Tcl_NewStringObj(m == interp ? "me" : m ? "other" : "NULL", -1));
        return TCL_OK;
    }
    if (!strcmp(op, "eval") && objc == 4) {
        Tcl_Interp *c = Child(interp, objv[2]);
        int rc = Tcl_EvalObjEx(c, objv[3], 0);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %s", rc, Tcl_GetStringResult(c)));
        return TCL_OK;
    }
    if (!strcmp(op, "makesafe") && objc == 3) {
        Tcl_Interp *c = Child(interp, objv[2]);
        return Ok(interp, Tcl_MakeSafe(c));
    }
    if (!strcmp(op, "whendeleted") && objc == 4) {
        Tcl_Interp *c = Child(interp, objv[2]);
        const char *tag = !strcmp(Tcl_GetString(objv[3]), "a") ? "a" : "b";
        Tcl_CallWhenDeleted(c, Gone, (ClientData)tag);
        return TCL_OK;
    }
    if (!strcmp(op, "dontcall") && objc == 4) {
        Tcl_Interp *c = Child(interp, objv[2]);
        const char *tag = !strcmp(Tcl_GetString(objv[3]), "a") ? "a" : "b";
        Tcl_DontCallWhenDeleted(c, Gone, (ClientData)tag);
        return TCL_OK;
    }
    if (!strcmp(op, "alias") && objc >= 6) {
        Tcl_Interp *s = Child(interp, objv[2]), *t = Child(interp, objv[4]);
        int rc;
        if (objc > 6 && !strcmp(Tcl_GetString(objv[6]), "-obj")) {
            rc = Tcl_CreateAliasObj(s, Tcl_GetString(objv[3]), t, Tcl_GetString(objv[5]), objc - 7, objv + 7);
        } else {
            const char *argv[8];
            int i, n = objc - 6 > 8 ? 8 : objc - 6;
            for (i = 0; i < n; i++) argv[i] = Tcl_GetString(objv[6 + i]);
            rc = Tcl_CreateAlias(s, Tcl_GetString(objv[3]), t, Tcl_GetString(objv[5]), n, argv);
        }
        return Ok(interp, rc);
    }
    if (!strcmp(op, "getalias") && objc == 4) {
        Tcl_Interp *s = Child(interp, objv[2]), *t = NULL, *t2 = NULL;
        const char *tc = NULL, *tc2 = NULL;
        int argc = 0, n2 = 0, i, rc;
        const char **argv = NULL;
        Tcl_Obj **ov = NULL, *out;
        rc = Tcl_GetAlias(s, Tcl_GetString(objv[3]), &t, &tc, &argc, &argv);
        if (rc != TCL_OK) {
            Tcl_SetObjResult(interp, Tcl_GetObjResult(s));
            return Ok(interp, rc);
        }
        Tcl_GetAliasObj(s, Tcl_GetString(objv[3]), &t2, &tc2, &n2, &ov);
        out = Tcl_ObjPrintf("%s %s %d", t == interp ? "me" : t == s ? "self" : "other", tc, argc);
        for (i = 0; i < argc; i++) Tcl_ListObjAppendElement(NULL, out, Tcl_NewStringObj(argv[i], -1));
        Tcl_ListObjAppendElement(NULL, out, Tcl_NewIntObj(t2 == t && !strcmp(tc, tc2) && n2 == argc));
        for (i = 0; i < n2; i++) Tcl_ListObjAppendElement(NULL, out, ov[i]);
        Tcl_SetObjResult(interp, out);
        return TCL_OK;
    }
    if (!strcmp(op, "hide") && objc == 5) {
        Tcl_Interp *c = Child(interp, objv[2]);
        int rc = Tcl_HideCommand(c, Tcl_GetString(objv[3]), Tcl_GetString(objv[4]));
        if (rc != TCL_OK) Tcl_SetObjResult(interp, Tcl_GetObjResult(c));
        return Ok(interp, rc);
    }
    if (!strcmp(op, "expose") && objc == 5) {
        Tcl_Interp *c = Child(interp, objv[2]);
        int rc = Tcl_ExposeCommand(c, Tcl_GetString(objv[3]), Tcl_GetString(objv[4]));
        if (rc != TCL_OK) Tcl_SetObjResult(interp, Tcl_GetObjResult(c));
        return Ok(interp, rc);
    }
    if (!strcmp(op, "recursion") && objc == 4) {
        Tcl_Interp *c = Child(interp, objv[2]);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_SetRecursionLimit(c, atoi(Tcl_GetString(objv[3])))));
        return TCL_OK;
    }
    if (!strcmp(op, "active") && objc == 3) {
        Tcl_Interp *c = Child(interp, objv[2]);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_InterpActive(c)));
        return TCL_OK;
    }
    if (!strcmp(op, "limits") && objc == 3) {
        Tcl_Interp *c = Child(interp, objv[2]);
        Tcl_Time t = {0, 0};
        Tcl_Obj *out = Tcl_NewObj();
        Tcl_AppendPrintfToObj(out, "cmd %d/%d/%d time %d/%d/%d ", Tcl_LimitTypeEnabled(c, TCL_LIMIT_COMMANDS),
            Tcl_LimitTypeExceeded(c, TCL_LIMIT_COMMANDS), Tcl_LimitGetGranularity(c, TCL_LIMIT_COMMANDS),
            Tcl_LimitTypeEnabled(c, TCL_LIMIT_TIME), Tcl_LimitTypeExceeded(c, TCL_LIMIT_TIME),
            Tcl_LimitGetGranularity(c, TCL_LIMIT_TIME));
        Tcl_LimitSetCommands(c, 1000000);
        Tcl_LimitSetGranularity(c, TCL_LIMIT_COMMANDS, 7);
        Tcl_LimitGetTime(c, &t);
        Tcl_AppendPrintfToObj(out, "get %d %d ", Tcl_LimitGetCommands(c), Tcl_LimitGetGranularity(c, TCL_LIMIT_COMMANDS));
        t.sec = 2000000000L;
        t.usec = 5;
        Tcl_LimitSetTime(c, &t);
        t.sec = 0;
        Tcl_LimitGetTime(c, &t);
        Tcl_AppendPrintfToObj(out, "time %ld %ld ", t.sec, t.usec);
        Tcl_LimitTypeSet(c, TCL_LIMIT_COMMANDS);
        Tcl_LimitTypeSet(c, TCL_LIMIT_TIME);
        Tcl_AppendPrintfToObj(out, "set %d %d ready %d ", Tcl_LimitTypeEnabled(c, TCL_LIMIT_COMMANDS), Tcl_LimitTypeEnabled(c, TCL_LIMIT_TIME), Tcl_LimitReady(c));
        Tcl_AppendPrintfToObj(out, "check %d exceeded %d ", Tcl_LimitCheck(c), Tcl_LimitExceeded(c));
        Tcl_LimitAddHandler(c, TCL_LIMIT_COMMANDS, LimitHit, "h1", LimitFree);
        Tcl_LimitAddHandler(c, TCL_LIMIT_COMMANDS, LimitHit, "h2", NULL);
        Tcl_LimitSetCommands(c, 0);
        Tcl_LimitSetGranularity(c, TCL_LIMIT_COMMANDS, 1);
        Tcl_AppendPrintfToObj(out, "check %d ", Tcl_LimitCheck(c));
        Tcl_AppendPrintfToObj(out, "<%s> exceeded %d %d ", Tcl_GetStringResult(c), Tcl_LimitExceeded(c), Tcl_LimitTypeExceeded(c, TCL_LIMIT_COMMANDS));
        Tcl_LimitRemoveHandler(c, TCL_LIMIT_COMMANDS, LimitHit, "h1");
        Tcl_LimitTypeReset(c, TCL_LIMIT_COMMANDS);
        Tcl_LimitTypeReset(c, TCL_LIMIT_TIME);
        Tcl_AppendPrintfToObj(out, "reset %d %d %d", Tcl_LimitTypeEnabled(c, TCL_LIMIT_COMMANDS), Tcl_LimitExceeded(c), Tcl_LimitCheck(c));
        Tcl_SetObjResult(interp, out);
        return TCL_OK;
    }
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("bad op %s", op));
    return TCL_ERROR;
}

#ifndef CX_INIT
#define CX_INIT Cxinterp_Init
#endif

int CX_INIT(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    log_ = Tcl_NewObj();
    Tcl_IncrRefCount(log_);
    Tcl_CreateObjCommand(interp, "cxinterp", InterpCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxinterp", "1.0");
}
