/* The test package of the execution traces: Tcl_CreateObjTrace,
 * Tcl_CreateTrace, and Tcl_DeleteTrace. The commands of the package
 * run from cxtrace.tcl.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <string.h>
#include <tcl.h>

#define MAX_TRACES 8

typedef struct {
    Tcl_Trace token;
    char tag[16];
    char deny[32];
    int code;
} Rec;

static Tcl_Obj *log_;
static Rec recs[MAX_TRACES];

static int ObjTracer(ClientData cd, Tcl_Interp *interp, int level, const char *command, Tcl_Command cmd, int objc, Tcl_Obj *const objv[]) {
    Rec *r = cd;
    int i;
    Tcl_AppendPrintfToObj(log_, "%s %d {%s} %s:", r->tag, level, command, cmd ? Tcl_GetCommandName(interp, cmd) : "?");
    for (i = 0; i < objc; i++) Tcl_AppendPrintfToObj(log_, " %s", Tcl_GetString(objv[i]));
    Tcl_AppendToObj(log_, "\n", 1);
    if (r->deny[0] && objc > 0 && !strcmp(Tcl_GetString(objv[0]), r->deny)) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s denied", r->deny));
        return r->code;
    }
    return TCL_OK;
}

static void StrTracer(ClientData cd, Tcl_Interp *interp, int level, char *command, Tcl_CmdProc *proc, ClientData cmdcd, int argc, const char *argv[]) {
    Rec *r = cd;
    int i;
    (void)interp;
    (void)cmdcd;
    Tcl_AppendPrintfToObj(log_, "%s %d {%s} %s:", r->tag, level, command, proc ? "proc" : "noproc");
    for (i = 0; i < argc; i++) Tcl_AppendPrintfToObj(log_, " %s", argv[i]);
    Tcl_AppendToObj(log_, "\n", 1);
}

static void Gone(ClientData cd) {
    Rec *r = cd;
    Tcl_AppendPrintfToObj(log_, "%s deleted\n", r->tag);
}

static Rec *Free(void) {
    int i;
    for (i = 0; i < MAX_TRACES; i++)
        if (!recs[i].token) return &recs[i];
    return NULL;
}

static Rec *Find(const char *tag) {
    int i;
    for (i = 0; i < MAX_TRACES; i++)
        if (recs[i].token && !strcmp(recs[i].tag, tag)) return &recs[i];
    return NULL;
}

/* cxtrace obj TAG LEVEL ?inline? ?deny WORD CODE?
 * cxtrace str TAG LEVEL
 * cxtrace delete TAG
 * cxtrace log */
static int TraceCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *op;
    Rec *r;
    int level, i, flags = 0;
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
    if (!strcmp(op, "delete") && objc == 3) {
        r = Find(Tcl_GetString(objv[2]));
        if (!r) return TCL_ERROR;
        Tcl_DeleteTrace(interp, r->token);
        r->token = NULL;
        return TCL_OK;
    }
    if (objc < 4 || Tcl_GetIntFromObj(interp, objv[3], &level) != TCL_OK) return TCL_ERROR;
    r = Free();
    if (!r) return TCL_ERROR;
    memset(r, 0, sizeof *r);
    strncpy(r->tag, Tcl_GetString(objv[2]), sizeof r->tag - 1);
    if (!strcmp(op, "str")) {
        r->token = Tcl_CreateTrace(interp, level, StrTracer, r);
        return TCL_OK;
    }
    for (i = 4; i < objc; i++) {
        const char *w = Tcl_GetString(objv[i]);
        if (!strcmp(w, "inline")) flags |= TCL_ALLOW_INLINE_COMPILATION;
        if (!strcmp(w, "deny") && i + 2 < objc) {
            strncpy(r->deny, Tcl_GetString(objv[i + 1]), sizeof r->deny - 1);
            if (Tcl_GetIntFromObj(interp, objv[i + 2], &r->code) != TCL_OK) return TCL_ERROR;
            i += 2;
        }
    }
    r->token = Tcl_CreateObjTrace(interp, level, flags, ObjTracer, r, Gone);
    return TCL_OK;
}

int Cxtrace_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    log_ = Tcl_NewObj();
    Tcl_IncrRefCount(log_);
    Tcl_CreateObjCommand(interp, "cxtrace", TraceCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxtrace", "1.0");
}
