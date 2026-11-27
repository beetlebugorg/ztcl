/* The test package of the area lists and dicts: the list text slots and
 * the dict slots. Cxdict_Init appends each result to a list and gives
 * the list as the error message of load.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <string.h>
#include <tcl.h>

static Tcl_Obj *out;

static void Put(const char *label, Tcl_Obj *v) {
    Tcl_Obj *pair = Tcl_NewListObj(0, NULL);
    Tcl_ListObjAppendElement(NULL, pair, Tcl_NewStringObj(label, -1));
    Tcl_ListObjAppendElement(NULL, pair, v);
    Tcl_ListObjAppendElement(NULL, out, pair);
}

static void PutErr(Tcl_Interp *interp, const char *label, int rc) {
    Put(label, Tcl_ObjPrintf("%d %s", rc, Tcl_GetStringResult(interp)));
    Tcl_ResetResult(interp);
}

static Tcl_Obj *S(const char *s) { return Tcl_NewStringObj(s, -1); }

/* The keys and the values of a dict, in the order of a search. */
static Tcl_Obj *Walk(Tcl_Interp *interp, Tcl_Obj *d) {
    Tcl_DictSearch s;
    Tcl_Obj *k, *v, *o = Tcl_NewObj();
    int done;
    if (Tcl_DictObjFirst(interp, d, &s, &k, &v, &done) != TCL_OK) return Tcl_GetObjResult(interp);
    for (; !done; Tcl_DictObjNext(&s, &k, &v, &done))
        Tcl_AppendPrintfToObj(o, "%s=%s;", Tcl_GetString(k), Tcl_GetString(v));
    Tcl_DictObjDone(&s);
    return o;
}

int Cxdict_Init(Tcl_Interp *interp) {
    static const char *words[] = { "a", "b c", "", "{x", "#h", "$v", "q\"r", "end]", "tab\there" };
    const int nw = sizeof words / sizeof words[0];
    char buf[200], *m;
    const char **argv;
    Tcl_Obj *d, *v, *keys[3];
    int i, n, flags, rc, argc;
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    out = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(out);

    /* The list text slots. */
    for (i = 0; i < nw; i++) {
        int len = Tcl_ScanElement(words[i], &flags);
        n = Tcl_ConvertElement(words[i], buf, flags | (i ? TCL_DONT_QUOTE_HASH : 0));
        Put("convertelement", Tcl_ObjPrintf("%s %d", buf, len >= n));
    }
    n = Tcl_ConvertElement("#h", buf, 0);
    Put("convertelement hash", S(buf));
    n = Tcl_ScanCountedElement("a b", 1, &flags);
    n = Tcl_ConvertCountedElement("a b", 1, buf, flags);
    Put("convertcounted", Tcl_ObjPrintf("%d %s", n, buf));
    m = Tcl_Merge(nw, words);
    Put("merge", S(m));
    rc = Tcl_SplitList(interp, m, &argc, &argv);
    Tcl_Free(m);
    {
        Tcl_Obj *o = Tcl_ObjPrintf("%d %d", rc, argc);
        for (i = 0; i < argc; i++) Tcl_AppendPrintfToObj(o, " <%s>", argv[i]);
        Put("splitlist", o);
        Put("splitlist end", Tcl_NewIntObj(argv[argc] == NULL));
        Tcl_Free((char *)argv);
    }
    rc = Tcl_SplitList(interp, "a {b", &argc, &argv);
    PutErr(interp, "splitlist bad", rc);
    m = Tcl_Merge(0, NULL);
    Put("merge empty", Tcl_ObjPrintf("<%s>", m));
    Tcl_Free(m);
    {
        static const char *parts[] = { "  a b ", "", "\tc\n", " " , "d" };
        Tcl_Obj *objs[3];
        m = Tcl_Concat(5, parts);
        Put("concat", Tcl_ObjPrintf("<%s>", m));
        Tcl_Free(m);
        objs[0] = S(" x "); objs[1] = S("{y z}"); objs[2] = S("");
        Put("concatobj", Tcl_ObjPrintf("<%s>", Tcl_GetString(Tcl_ConcatObj(3, objs))));
    }

    /* Dicts. */
    d = Tcl_NewDictObj();
    Tcl_IncrRefCount(d);
    Tcl_DictObjPut(interp, d, S("one"), S("1"));
    Tcl_DictObjPut(interp, d, S("two"), S("2 2"));
    Tcl_DictObjPut(interp, d, S("three"), S("3"));
    Tcl_DictObjPut(interp, d, S("one"), S("uno"));
    Put("dict text", Tcl_DuplicateObj(d));
    Tcl_DictObjSize(interp, d, &n);
    Put("dict size", Tcl_NewIntObj(n));
    Tcl_DictObjGet(interp, d, S("two"), &v);
    Put("dict get", v);
    Tcl_DictObjGet(interp, d, S("none"), &v);
    Put("dict get none", Tcl_NewIntObj(v == NULL));
    Tcl_DictObjRemove(interp, d, S("one"));
    Tcl_DictObjRemove(interp, d, S("none"));
    Put("dict remove", Tcl_DuplicateObj(d));
    Put("dict walk", Walk(interp, d));
    keys[0] = S("a"); keys[1] = S("b"); keys[2] = S("c");
    for (i = 0; i < 3; i++) Tcl_IncrRefCount(keys[i]);
    rc = Tcl_DictObjPutKeyList(interp, d, 3, keys, S("deep"));
    Put("putkeylist", Tcl_ObjPrintf("%d %s", rc, Tcl_GetString(d)));
    rc = Tcl_DictObjPutKeyList(interp, d, 2, keys, S("flat"));
    Put("putkeylist replace", Tcl_ObjPrintf("%d %s", rc, Tcl_GetString(d)));
    rc = Tcl_DictObjPutKeyList(interp, d, 3, keys, S("v"));
    PutErr(interp, "putkeylist notdict", rc);
    rc = Tcl_DictObjRemoveKeyList(interp, d, 2, keys);
    Put("removekeylist", Tcl_ObjPrintf("%d %s", rc, Tcl_GetString(d)));
    rc = Tcl_DictObjRemoveKeyList(interp, d, 3, keys + 0);
    PutErr(interp, "removekeylist missing", rc);
    {
        Tcl_Obj *k2[2];
        k2[0] = S("zz"); k2[1] = S("y");
        rc = Tcl_DictObjRemoveKeyList(interp, d, 2, k2);
        PutErr(interp, "removekeylist unknown", rc);
    }
    for (i = 0; i < 3; i++) Tcl_DecrRefCount(keys[i]);
    Tcl_DecrRefCount(d);

    /* A dict from a list text. */
    d = S("k1 v1 k2 {v 2} k1 last");
    Tcl_IncrRefCount(d);
    Tcl_DictObjSize(interp, d, &n);
    Put("fromtext size", Tcl_NewIntObj(n));
    Put("fromtext walk", Walk(interp, d));
    Tcl_DictObjPut(interp, d, S("k3"), S("x"));
    Put("fromtext put", Tcl_DuplicateObj(d));
    Tcl_DecrRefCount(d);
    d = S("a b c");
    rc = Tcl_DictObjSize(interp, d, &n);
    PutErr(interp, "fromtext odd", rc);
    d = S("a {b");
    rc = Tcl_DictObjGet(interp, d, S("a"), &v);
    PutErr(interp, "fromtext badlist", rc);
    d = Tcl_NewDictObj();
    Put("empty", Tcl_ObjPrintf("<%s> %s", Tcl_GetString(d), Tcl_GetString(Walk(interp, d))));
    d = Tcl_DbNewDictObj(__FILE__, __LINE__);
    Tcl_DictObjPut(interp, d, S("{"), S("}"));
    Put("dbnew", d);

    /* A search sees the dict at its start. */
    d = S("a 1 b 2");
    Tcl_IncrRefCount(d);
    {
        Tcl_DictSearch s;
        Tcl_Obj *k;
        int done;
        Tcl_Obj *o = Tcl_NewObj();
        Tcl_DictObjFirst(interp, d, &s, &k, NULL, &done);
        Tcl_AppendPrintfToObj(o, "%s", Tcl_GetString(k));
        Tcl_DictObjDone(&s);
        Put("search keys only", o);
    }
    Tcl_DecrRefCount(d);

    Tcl_SetObjResult(interp, out);
    Tcl_DecrRefCount(out);
    return TCL_ERROR;
}
