/* The test package of threads, mutexes, conditions, thread data, the
 * time, and the command info slots: src/cext/threads.zig and
 * src/cext/cmds.zig.
 * SPDX-License-Identifier: BSD-2-Clause */
#define TCL_THREADS 1
#include <string.h>
#include <tcl.h>

static Tcl_Mutex lock;
static Tcl_Condition cond;
static int counter, started;
static Tcl_ThreadDataKey dataKey;
static Tcl_CmdInfo saved;
static int exits;
static Tcl_Command nameTok;

typedef struct { int calls; } Data;

static int DataCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Data *d = (Data *) Tcl_GetThreadData(&dataKey, sizeof(Data));
    (void)cd; (void)objc; (void)objv;
    d->calls++;
    Tcl_SetObjResult(interp, Tcl_NewIntObj(d->calls));
    return TCL_OK;
}

static void OnExit(ClientData cd) {
    Tcl_MutexLock(&lock);
    exits += (int)(size_t)cd;
    Tcl_MutexUnlock(&lock);
}

static Tcl_ThreadCreateType Worker(ClientData cd) {
    int i;
    Data *d = (Data *) Tcl_GetThreadData(&dataKey, sizeof(Data));
    /* The block of a new thread starts with zeros. */
    int fresh = d->calls == 0;
    Tcl_CreateThreadExitHandler(OnExit, (ClientData) 1);
    Tcl_MutexLock(&lock);
    started++;
    Tcl_ConditionNotify(&cond);
    Tcl_MutexUnlock(&lock);
    for (i = 0; i < 1000; i++) {
        Tcl_MutexLock(&lock);
        counter++;
        Tcl_MutexUnlock(&lock);
    }
    Tcl_ExitThread((int)(size_t)cd + (fresh ? 100 : 0));
    TCL_THREAD_CREATE_RETURN;
}

/* cxthr::run N: N threads add 1000 each under the mutex. The result is
 * the count, the sum of the join codes, and the count of exit handlers. */
static int RunCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int n, i, sum = 0, code;
    Tcl_ThreadId ids[16];
    Tcl_Obj *r;
    (void)cd;
    if (objc != 2 || Tcl_GetIntFromObj(interp, objv[1], &n) != TCL_OK || n < 1 || n > 16) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("usage: cxthr::run 1..16", -1));
        return TCL_ERROR;
    }
    counter = started = exits = 0;
    for (i = 0; i < n; i++) {
        if (Tcl_CreateThread(&ids[i], Worker, (ClientData)(size_t) i, TCL_THREAD_STACK_DEFAULT, TCL_THREAD_JOINABLE) != TCL_OK) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("no thread", -1));
            return TCL_ERROR;
        }
    }
    Tcl_MutexLock(&lock);
    while (started < n) Tcl_ConditionWait(&cond, &lock, NULL);
    Tcl_MutexUnlock(&lock);
    for (i = 0; i < n; i++) {
        if (Tcl_JoinThread(ids[i], &code) != TCL_OK) return TCL_ERROR;
        sum += code;
    }
    r = Tcl_NewListObj(0, NULL);
    Tcl_ListObjAppendElement(NULL, r, Tcl_NewIntObj(counter));
    Tcl_ListObjAppendElement(NULL, r, Tcl_NewIntObj(sum));
    Tcl_ListObjAppendElement(NULL, r, Tcl_NewIntObj(exits));
    Tcl_SetObjResult(interp, r);
    return TCL_OK;
}

/* cxthr::wait MS: a wait with a limit and no notify. The result is 1
 * when the wait took at least MS - 1 milliseconds. */
static int WaitCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    static Tcl_Condition quiet;
    int ms;
    long el;
    Tcl_Time t0, t1, limit;
    (void)cd;
    if (objc != 2 || Tcl_GetIntFromObj(interp, objv[1], &ms) != TCL_OK) return TCL_ERROR;
    limit.sec = ms / 1000;
    limit.usec = (ms % 1000) * 1000;
    Tcl_GetTime(&t0);
    Tcl_MutexLock(&lock);
    Tcl_ConditionWait(&quiet, &lock, &limit);
    Tcl_MutexUnlock(&lock);
    Tcl_Sleep(1);
    Tcl_GetTime(&t1);
    el = (t1.sec - t0.sec) * 1000 + (t1.usec - t0.usec) / 1000;
    Tcl_SetObjResult(interp, Tcl_NewIntObj(el >= ms - 1));
    Tcl_ConditionFinalize(&quiet);
    return TCL_OK;
}

static int Dash(ClientData cd, Tcl_Interp *interp, int argc, const char *argv[]) {
    int i;
    Tcl_ResetResult(interp);
    for (i = 1; i < argc; i++) {
        if (i > 1) Tcl_AppendResult(interp, "-", NULL);
        Tcl_AppendResult(interp, argv[i], NULL);
    }
    if (cd != NULL) Tcl_AppendResult(interp, (const char *) cd, NULL);
    return TCL_OK;
}

/* cxthr::wrap NAME: saves the info of NAME and makes cxthr::orig, which
 * calls the saved object function. */
static int Orig(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    return saved.objProc(saved.objClientData, interp, objc, objv);
}

static int WrapCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) return TCL_ERROR;
    if (!Tcl_GetCommandInfo(interp, Tcl_GetString(objv[1]), &saved)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("no command", -1));
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "cxthr::orig", Orig, NULL, NULL);
    Tcl_SetObjResult(interp, Tcl_NewIntObj(saved.isNativeObjectProc));
    return TCL_OK;
}

/* cxthr::info NAME: isNativeObjectProc, and the string function of the
 * info called with the words a b. */
static int InfoCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_CmdInfo info;
    const char *argv[] = { NULL, "a", "b", NULL };
    char buf[32];
    int code;
    (void)cd;
    if (objc != 2) return TCL_ERROR;
    if (!Tcl_GetCommandInfo(interp, Tcl_GetString(objv[1]), &info)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("none", -1));
        return TCL_OK;
    }
    argv[0] = Tcl_GetString(objv[1]);
    code = info.proc(info.clientData, interp, 3, argv);
    sprintf(buf, "%d %d ", info.isNativeObjectProc, code);
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s%s", buf, Tcl_GetStringResult(interp)));
    return TCL_OK;
}

/* cxthr::retarget: points the string function of cxthr::dash at the
 * data "!" with Tcl_SetCommandInfo. */
static int RetargetCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_CmdInfo info;
    (void)cd; (void)objc; (void)objv;
    if (!Tcl_GetCommandInfo(interp, "cxthr::dash", &info)) return TCL_ERROR;
    info.clientData = (ClientData) "!";
    Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_SetCommandInfo(interp, "cxthr::dash", &info)));
    return TCL_OK;
}

static int NameCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_Command tok = nameTok;
    Tcl_Obj *full = Tcl_NewObj();
    (void)objc; (void)objv;
    Tcl_GetCommandFullName(interp, tok, full);
    Tcl_AppendResult(interp, Tcl_GetCommandName(interp, tok), " ", Tcl_GetString(full), NULL);
    Tcl_DecrRefCount(full);
    return TCL_OK;
}

int Cxthr_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxthr::data", DataCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxthr::run", RunCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxthr::wait", WaitCmd, NULL, NULL);
    Tcl_CreateCommand(interp, "cxthr::dash", Dash, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxthr::wrap", WrapCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxthr::info", InfoCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "cxthr::retarget", RetargetCmd, NULL, NULL);
    nameTok = Tcl_CreateObjCommand(interp, "cxthr::name", NameCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxthr", "1.0");
}
