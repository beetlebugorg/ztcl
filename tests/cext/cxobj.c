/* The test package of the area objects. Cxobj_Init runs each check and
 * appends its result to a list. The init gives the list as the error
 * message of load, so the script prints it line by line.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdarg.h>
#include <string.h>
#include <tcl.h>

static Tcl_Obj *out;

static void Put(Tcl_Interp *interp, const char *label, Tcl_Obj *v) {
    Tcl_Obj *pair = Tcl_NewListObj(0, NULL);
    Tcl_ListObjAppendElement(interp, pair, Tcl_NewStringObj(label, -1));
    Tcl_ListObjAppendElement(interp, pair, v);
    Tcl_ListObjAppendElement(interp, out, pair);
}

static void PutInt(Tcl_Interp *interp, const char *label, int rc, long v) {
    Tcl_Obj *o = rc == TCL_OK ? Tcl_NewLongObj(v) : Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    Tcl_ResetResult(interp);
    Put(interp, label, o);
}

/* A type of the package: the internal form is the length of the text. */
static int SetLen(Tcl_Interp *interp, Tcl_Obj *o);
static void UpdateLen(Tcl_Obj *o) { (void)o; }
static const Tcl_ObjType lenType = { "cxlen", NULL, NULL, UpdateLen, SetLen };
static int SetLen(Tcl_Interp *interp, Tcl_Obj *o) {
    int n;
    (void)interp;
    Tcl_GetStringFromObj(o, &n);
    if (o->typePtr && o->typePtr->freeIntRepProc) o->typePtr->freeIntRepProc(o);
    o->internalRep.longValue = n;
    o->typePtr = &lenType;
    return TCL_OK;
}

static void Strings(Tcl_Obj *o, ...) {
    va_list ap;
    va_start(ap, o);
    Tcl_AppendStringsToObjVA(o, ap);
    va_end(ap);
}

static const char *opts[] = { "alpha", "beta", "gamma", NULL };

int Cxobj_Init(Tcl_Interp *interp) {
    int i, n, rc;
    double d;
    Tcl_Obj *o, *l;
    unsigned char *b;
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    out = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(out);

    rc = Tcl_GetInt(interp, "0x10", &i); PutInt(interp, "getint hex", rc, i);
    rc = Tcl_GetInt(interp, " 12 ", &i); PutInt(interp, "getint space", rc, i);
    rc = Tcl_GetInt(interp, "12z", &i); PutInt(interp, "getint bad", rc, i);
    rc = Tcl_GetBoolean(interp, "yes", &i); PutInt(interp, "getboolean yes", rc, i);
    rc = Tcl_GetBoolean(interp, "maybe", &i); PutInt(interp, "getboolean bad", rc, i);
    rc = Tcl_GetDouble(interp, "1e3", &d); PutInt(interp, "getdouble", rc, (long)d);
    rc = Tcl_GetDouble(interp, "x", &d); PutInt(interp, "getdouble bad", rc, 0);

    o = Tcl_NewStringObj("be", -1);
    rc = Tcl_GetIndexFromObj(interp, o, opts, "option", 0, &i); PutInt(interp, "index prefix", rc, i);
    Tcl_SetStringObj(o, "zeta", -1);
    rc = Tcl_GetIndexFromObj(interp, o, opts, "option", 0, &i); PutInt(interp, "index bad", rc, i);
    Tcl_SetStringObj(o, "beta", -1);
    rc = Tcl_GetIndexFromObj(interp, o, opts, "option", TCL_EXACT, &i); PutInt(interp, "index exact", rc, i);

    Tcl_SetStringObj(o, "abcdef", -1);
    Tcl_SetObjLength(o, 3);
    Put(interp, "setobjlength", Tcl_DuplicateObj(o));
    Tcl_SetObjLength(o, 5);
    memcpy(Tcl_GetString(o) + 3, "XY", 2);
    Put(interp, "setobjlength grow", Tcl_DuplicateObj(o));
    PutInt(interp, "attemptsetobjlength", TCL_OK, Tcl_AttemptSetObjLength(o, 1));

    l = Tcl_NewByteArrayObj((const unsigned char *)"\x01\x02\x03", 3);
    b = Tcl_SetByteArrayLength(l, 5);
    b[4] = 7;
    Tcl_GetByteArrayFromObj(l, &n);
    PutInt(interp, "setbytearraylength", TCL_OK, n * 1000 + b[0] * 100 + b[2] * 10 + b[4]);

    Put(interp, "int type", Tcl_NewStringObj(Tcl_NewIntObj(3)->typePtr->name, -1));
    Put(interp, "getobjtype list", Tcl_NewStringObj(Tcl_GetObjType("list") ? Tcl_GetObjType("list")->name : "none", -1));
    Put(interp, "getobjtype none", Tcl_NewStringObj(Tcl_GetObjType("cxlen") ? "found" : "none", -1));
    Tcl_RegisterObjType(&lenType);
    Put(interp, "getobjtype cxlen", Tcl_NewStringObj(Tcl_GetObjType("cxlen") == &lenType ? "found" : "none", -1));

    Tcl_SetStringObj(o, "hello", -1);
    rc = Tcl_ConvertToType(interp, o, &lenType);
    PutInt(interp, "converttotype cxlen", rc, o->typePtr == &lenType ? o->internalRep.longValue : -1);
    Tcl_SetStringObj(o, "{a", -1);
    rc = Tcl_ConvertToType(interp, o, Tcl_GetObjType("list")); PutInt(interp, "converttotype list", rc, 0);
    Tcl_SetStringObj(o, "a b c", -1);
    rc = Tcl_ConvertToType(interp, o, Tcl_GetObjType("list"));
    Tcl_ListObjLength(interp, o, &n);
    PutInt(interp, "converttotype list ok", rc, n);

    l = Tcl_NewListObj(0, NULL);
    rc = Tcl_AppendAllObjTypes(interp, l);
    Tcl_ListObjLength(interp, l, &n);
    {
        Tcl_Obj **v; int k, has = 0;
        Tcl_ListObjGetElements(interp, l, &n, &v);
        for (k = 0; k < n; k++) {
            const char *t = Tcl_GetString(v[k]);
            if (!strcmp(t, "list") || !strcmp(t, "double") || !strcmp(t, "bytearray") || !strcmp(t, "cxlen")) has++;
        }
        PutInt(interp, "appendallobjtypes", rc, has);
    }

    Tcl_SetStringObj(o, "a", -1);
    Strings(o, "b", "cd", NULL);
    Put(interp, "appendstringsva", Tcl_DuplicateObj(o));

    Put(interp, "dbnew", Tcl_DbNewStringObj("s", -1, __FILE__, __LINE__));
    Put(interp, "dbnewlong", Tcl_DbNewLongObj(-5, __FILE__, __LINE__));
    Put(interp, "dbnewdouble", Tcl_DbNewDoubleObj(2.5, __FILE__, __LINE__));
    Put(interp, "dbnewbool", Tcl_DbNewBooleanObj(7, __FILE__, __LINE__));
    Put(interp, "dbnewwide", Tcl_DbNewWideIntObj((Tcl_WideInt)1 << 40, __FILE__, __LINE__));
    Put(interp, "dbnewlist", Tcl_DbNewListObj(0, NULL, __FILE__, __LINE__));
    Put(interp, "dbnewobj", Tcl_DbNewObj(__FILE__, __LINE__));
    Put(interp, "dbnewbytes", Tcl_DbNewByteArrayObj((const unsigned char *)"ab", 2, __FILE__, __LINE__));

    Tcl_SetObjResult(interp, out);
    Tcl_DecrRefCount(out);
    return TCL_ERROR;
}
