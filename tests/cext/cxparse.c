/* The test package of the parse slots and Tcl_ParseArgsObjv.
 *   cxparse command|expr|braces|quoted|varname TEXT
 * gives the fields of the Tcl_Parse and one line for each token: the
 * type, the numComponents, and the text.
 *   cxparse words SCRIPT    gives the words of each command after
 *                           Tcl_EvalTokensStandard.
 *   cxparse var TEXT        gives Tcl_ParseVar and the rest of TEXT.
 *   cxparse tokens TEXT     gives Tcl_EvalTokens of the first word.
 *   cxparse args ARG...     runs Tcl_ParseArgsObjv on the arguments.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdio.h>
#include <string.h>
#include <tcl.h>

static void Fields(Tcl_Obj *out, Tcl_Parse *p, const char *s, int code) {
    char buf[200];
    int i;
    snprintf(buf, sizeof buf, "code %d words %d tokens %d term %d incomplete %d errorType %d",
            code, p->numWords, p->numTokens, (int)(p->term - s), p->incomplete, p->errorType);
    Tcl_AppendToObj(out, buf, -1);
    if (code != TCL_OK) return;
    for (i = 0; i < p->numTokens; i++) {
        Tcl_Token *t = &p->tokenPtr[i];
        snprintf(buf, sizeof buf, "\n  %d %d at %d: ", t->type, t->numComponents, (int)(t->start - s));
        Tcl_AppendToObj(out, buf, -1);
        Tcl_AppendToObj(out, t->start, t->size);
    }
}

static int ParseCmd(Tcl_Interp *interp, const char *mode, const char *s, int len) {
    Tcl_Parse p;
    Tcl_Obj *out = Tcl_NewObj();
    const char *term = NULL;
    char buf[200];
    int code;
    if (!strcmp(mode, "command")) {
        const char *at = s;
        int left = len;
        /* Each command of the script, in order. */
        do {
            code = Tcl_ParseCommand(interp, at, left, 0, &p);
            if (code == TCL_OK) {
                snprintf(buf, sizeof buf, "command at %d size %d comment %d size %d\n",
                        (int)(p.commandStart - s), p.commandSize,
                        p.commentStart ? (int)(p.commentStart - s) : -1, p.commentSize);
            } else {
                snprintf(buf, sizeof buf, "error ");
            }
            Tcl_AppendToObj(out, buf, -1);
            Fields(out, &p, s, code);
            if (code != TCL_OK) {
                Tcl_AppendToObj(out, "\n  ", -1);
                Tcl_AppendObjToObj(out, Tcl_GetObjResult(interp));
                break;
            }
            Tcl_AppendToObj(out, "\n", -1);
            left -= (int)(p.commandStart + p.commandSize - at);
            at = p.commandStart + p.commandSize;
            Tcl_FreeParse(&p);
        } while (left > 0);
        Tcl_SetObjResult(interp, out);
        return TCL_OK;
    }
    Tcl_ResetResult(interp);
    if (!strcmp(mode, "expr")) {
        code = Tcl_ParseExpr(interp, s, len, &p);
    } else if (!strcmp(mode, "braces")) {
        code = Tcl_ParseBraces(interp, s, len, &p, 0, &term);
    } else if (!strcmp(mode, "quoted")) {
        code = Tcl_ParseQuotedString(interp, s, len, &p, 0, &term);
    } else {
        code = Tcl_ParseVarName(interp, s, len, &p, 0);
    }
    Fields(out, &p, s, code);
    if (term) {
        snprintf(buf, sizeof buf, "\n  end at %d", (int)(term - s));
        Tcl_AppendToObj(out, buf, -1);
    }
    if (code != TCL_OK) {
        Tcl_AppendToObj(out, "\n  ", -1);
        Tcl_AppendObjToObj(out, Tcl_GetObjResult(interp));
    } else {
        Tcl_FreeParse(&p);
    }
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

static int Words(Tcl_Interp *interp, const char *s, int len) {
    Tcl_Parse p;
    Tcl_Obj *out = Tcl_NewObj();
    int i, w, code;
    while (len > 0) {
        Tcl_Obj *cmd = Tcl_NewObj();
        if (Tcl_ParseCommand(interp, s, len, 0, &p) != TCL_OK) return TCL_ERROR;
        for (w = 0, i = 0; w < p.numWords; w++) {
            Tcl_Token *t = &p.tokenPtr[i];
            code = Tcl_EvalTokensStandard(interp, t + 1, t->numComponents);
            if (code != TCL_OK) {
                Tcl_FreeParse(&p);
                return code;
            }
            Tcl_ListObjAppendElement(interp, cmd, Tcl_GetObjResult(interp));
            i += t->numComponents + 1;
        }
        if (p.numWords) Tcl_ListObjAppendElement(interp, out, cmd);
        else Tcl_DecrRefCount(cmd);
        len -= (int)(p.commandStart + p.commandSize - s);
        s = p.commandStart + p.commandSize;
        Tcl_FreeParse(&p);
    }
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

static int counted;

static int Count(ClientData cd, Tcl_Obj *arg, void *dst) {
    (void)cd;
    (void)arg;
    *(int *)dst += 1;
    return 0;
}

static int Gen(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const *objv, void *dst) {
    (void)cd;
    if (objc < 2) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("-pair needs two values", -1));
        return -1;
    }
    *(Tcl_Obj **)dst = Tcl_NewStringObj(Tcl_GetString(objv[0]), -1);
    Tcl_AppendStringsToObj(*(Tcl_Obj **)dst, "+", Tcl_GetString(objv[1]), (char *)NULL);
    return 2;
}

static int Args(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], int rest) {
    int n = 0, verbose = 0, restAt = -1, i;
    double ratio = 1.5;
    const char *name = "none";
    Tcl_Obj *pair = NULL;
    Tcl_Obj **rem = NULL;
    char buf[300];
    Tcl_ArgvInfo table[] = {
        {TCL_ARGV_INT, "-count", NULL, &n, "a count", NULL},
        {TCL_ARGV_FLOAT, "-ratio", NULL, &ratio, "a ratio", NULL},
        {TCL_ARGV_STRING, "-name", NULL, (void *)&name, "a name", NULL},
        {TCL_ARGV_CONSTANT, "-verbose", (void *)(size_t)7, &verbose, "talk more", NULL},
        {TCL_ARGV_CONSTANT, "-version", (void *)(size_t)1, &verbose, "version", NULL},
        {TCL_ARGV_FUNC, "-tick", (void *)Count, &counted, "count ticks", NULL},
        {TCL_ARGV_GENFUNC, "-pair", (void *)Gen, &pair, "two values", NULL},
        {TCL_ARGV_REST, "--", NULL, &restAt, "end of options", NULL},
        {TCL_ARGV_HELP, NULL, NULL, NULL, "The options of cxparse args:", NULL},
        TCL_ARGV_AUTO_HELP,
        TCL_ARGV_TABLE_END
    };
    counted = 0;
    if (Tcl_ParseArgsObjv(interp, table, &objc, objv, rest ? &rem : NULL) != TCL_OK) return TCL_ERROR;
    snprintf(buf, sizeof buf, "count %d ratio %g name %s verbose %d ticks %d pair %s rest %d left %d:",
            n, ratio, name, verbose, counted, pair ? Tcl_GetString(pair) : "-", restAt, objc);
    Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
    if (rem) {
        for (i = 0; i < objc; i++) {
            Tcl_AppendStringsToObj(Tcl_GetObjResult(interp), " ", Tcl_GetString(rem[i]), (char *)NULL);
        }
        if (rem[objc] != NULL) Tcl_AppendToObj(Tcl_GetObjResult(interp), " (no null)", -1);
        ckfree(rem);
    }
    return TCL_OK;
}

static int CxParse(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *mode, *s;
    int len;
    (void)cd;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "mode ?arg ...?");
        return TCL_ERROR;
    }
    mode = Tcl_GetString(objv[1]);
    if (!strcmp(mode, "args")) return Args(interp, objc - 1, objv + 1, 0);
    if (!strcmp(mode, "argsrest")) return Args(interp, objc - 1, objv + 1, 1);
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 2, objv, "text");
        return TCL_ERROR;
    }
    s = Tcl_GetStringFromObj(objv[2], &len);
    if (!strcmp(mode, "words")) return Words(interp, s, len);
    if (!strcmp(mode, "var")) {
        const char *term = NULL;
        const char *v = Tcl_ParseVar(interp, s, &term);
        if (v == NULL) return TCL_ERROR;
        Tcl_Obj *o = Tcl_NewStringObj(v, -1);
        Tcl_AppendStringsToObj(o, "|", term, (char *)NULL);
        Tcl_SetObjResult(interp, o);
        return TCL_OK;
    }
    if (!strcmp(mode, "tokens")) {
        Tcl_Parse p;
        Tcl_Obj *o;
        if (Tcl_ParseCommand(interp, s, len, 0, &p) != TCL_OK) return TCL_ERROR;
        o = Tcl_EvalTokens(interp, p.tokenPtr + 1, p.tokenPtr->numComponents);
        Tcl_FreeParse(&p);
        if (o == NULL) return TCL_ERROR;
        Tcl_SetObjResult(interp, o);
        Tcl_DecrRefCount(o);
        return TCL_OK;
    }
    return ParseCmd(interp, mode, s, len);
}

int Cxparse_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxparse", CxParse, NULL, NULL);
    return Tcl_PkgProvideEx(interp, "cxparse", "1.0", NULL);
}
