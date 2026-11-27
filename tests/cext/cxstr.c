/* The test package of the area strings: format and append, the UTF-8
 * and Tcl_UniChar functions, classes, case maps, matches, backslashes,
 * and the Unicode form of an object. Cxstr_Init appends each result to
 * a list and gives the list as the error message of load.
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

static void PutInt(const char *label, long v) { Put(label, Tcl_NewLongObj(v)); }
static void PutStr(const char *label, const char *s) { Put(label, Tcl_NewStringObj(s, -1)); }

/* The bytes of a string as hex, so that C0 80 and bad bytes show. */
static void PutHex(const char *label, const char *s, int n) {
    Tcl_Obj *o = Tcl_NewObj();
    int i;
    for (i = 0; i < n; i++) Tcl_AppendPrintfToObj(o, "%02x", (unsigned char)s[i]);
    Put(label, o);
}

static void PutUni(const char *label, const Tcl_UniChar *u, int n) {
    Tcl_Obj *o = Tcl_NewObj();
    int i;
    for (i = 0; i < n; i++) Tcl_AppendPrintfToObj(o, "%s%04x", i ? " " : "", u[i]);
    Put(label, o);
}

static void Fmt(Tcl_Interp *interp, const char *label, const char *fmt, int objc, Tcl_Obj *const objv[]) {
    Tcl_Obj *r = Tcl_Format(interp, fmt, objc, objv);
    if (r == NULL) {
        r = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
        Tcl_ResetResult(interp);
        Tcl_AppendToObj(r, " (error)", -1);
    }
    Put(label, r);
}

int Cxstr_Init(Tcl_Interp *interp) {
    Tcl_Obj *o, *v[4];
    Tcl_DString ds;
    Tcl_UniChar ch, *u;
    char buf[64];
    const char *s, *p, *bad = "%q";
    int n, rd, i;
    static const Tcl_UniChar abc[] = { 'a', 0xe9, 0x4e2d, 'Z', 0 };
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    out = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(out);

    /* Tcl_ObjPrintf and Tcl_AppendPrintfToObj. */
    Put("printf int", Tcl_ObjPrintf("%d|%5d|%-5d|%05d|%+d|%x|%X|%o|%u", 42, -7, 3, 12, 9, 255, 255, 8, 3000000000u));
    Put("printf long", Tcl_ObjPrintf("%ld %lld %lx", 1234567890L, -9876543210LL, 0xabcdefL));
    Put("printf str", Tcl_ObjPrintf("[%s] [%10s] [%-6s] [%.2s] [%.*s]", "hi", "right", "left", "abcdef", 3, "xyzw"));
    Put("printf star", Tcl_ObjPrintf("[%*d] [%-*d]", 6, 42, 4, 7));
    Put("printf char", Tcl_ObjPrintf("%c%c%c", 'T', 0xe9, 0x4e2d));
    Put("printf double", Tcl_ObjPrintf("%f %.2f %e %g %G %10.3f", 3.5, 2.675, 12345.678, 0.0001, 1e20, -1.5));
    Put("printf pct", Tcl_ObjPrintf("100%% %s", "done"));
    Put("printf utf", Tcl_ObjPrintf("%.2s|%5s|", "\xc3\xa9t\xc3\xa9", "\xc3\xa9"));
    Put("printf bad", Tcl_ObjPrintf(bad, 1));
    o = Tcl_NewStringObj("pre:", -1);
    Tcl_AppendPrintfToObj(o, "%s=%d", "x", 5);
    Tcl_AppendPrintfToObj(o, ";%s", "end");
    Put("appendprintf", o);

    /* Tcl_Format and Tcl_AppendFormatToObj. */
    v[0] = Tcl_NewStringObj("abc", -1);
    v[1] = Tcl_NewIntObj(17);
    v[2] = Tcl_NewDoubleObj(1.25);
    v[3] = Tcl_NewStringObj("12", -1);
    for (i = 0; i < 4; i++) Tcl_IncrRefCount(v[i]);
    Fmt(interp, "format basic", "%s-%d-%.3f-%s", 4, v);
    Fmt(interp, "format pos", "%2$d %1$s %2$x", 2, v);
    Fmt(interp, "format few", "%s %s %s", 2, v);
    Fmt(interp, "format notint", "%d", 1, v);
    Fmt(interp, "format notdouble", "%f", 1, v);
    Fmt(interp, "format badspec", "%y", 1, v);
    Fmt(interp, "format mix", "%1$s %s", 2, v);
    Fmt(interp, "format end", "abc%", 0, v);
    Fmt(interp, "format char", "%c", 1, v + 1);
    Fmt(interp, "format wide", "%lld %llx", 1, v + 3);
    o = Tcl_NewStringObj("[", -1);
    n = Tcl_AppendFormatToObj(interp, o, "%s|%5s]", 2, v);
    PutInt("appendformat rc", n);
    Put("appendformat", o);
    n = Tcl_AppendFormatToObj(NULL, o, "%d", 1, v);
    PutInt("appendformat null interp rc", n);
    Put("appendformat after error", o);
    for (i = 0; i < 4; i++) Tcl_DecrRefCount(v[i]);

    /* Tcl_AppendLimitedToObj. */
    o = Tcl_NewObj();
    Tcl_AppendLimitedToObj(o, "short", -1, 10, NULL);
    Put("limited fits", o);
    o = Tcl_NewObj();
    Tcl_AppendLimitedToObj(o, "abcdefghijkl", -1, 8, NULL);
    Put("limited cut", o);
    o = Tcl_NewObj();
    Tcl_AppendLimitedToObj(o, "abcdefghijkl", 12, 6, "~");
    Put("limited ellipsis", o);
    o = Tcl_NewObj();
    Tcl_AppendLimitedToObj(o, "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9", -1, 6, "..");
    Put("limited utf", o);
    o = Tcl_NewObj();
    Tcl_AppendLimitedToObj(o, "abcdef", -1, 2, "...");
    Put("limited small", o);

    /* UTF-8 functions. */
    s = "a\xc3\xa9\xe4\xb8\xadZ";
    PutInt("numutfchars", Tcl_NumUtfChars(s, -1));
    PutInt("numutfchars len", Tcl_NumUtfChars(s, 3));
    n = Tcl_UtfToUniChar(s + 1, &ch);
    Put("utftounichar", Tcl_ObjPrintf("%d %04x", n, ch));
    n = Tcl_UtfToUniChar("\xc0\x80", &ch);
    Put("utftounichar nul", Tcl_ObjPrintf("%d %04x", n, ch));
    n = Tcl_UtfToUniChar("\xff", &ch);
    Put("utftounichar bad", Tcl_ObjPrintf("%d %04x", n, ch));
    n = Tcl_UniCharToUtf(0x4e2d, buf);
    PutHex("unichartoutf", buf, n);
    n = Tcl_UniCharToUtf(0, buf);
    PutHex("unichartoutf nul", buf, n);
    n = Tcl_UniCharToUtf('q', buf);
    PutHex("unichartoutf ascii", buf, n);
    PutStr("utfatindex", Tcl_UtfAtIndex(s, 2));
    PutInt("unicharatindex", Tcl_UniCharAtIndex(s, 2));
    PutInt("utfcharcomplete", Tcl_UtfCharComplete(s + 3, 2) * 10 + Tcl_UtfCharComplete(s + 3, 3));
    PutStr("utfnext", Tcl_UtfNext(s + 1));
    PutStr("utfprev", Tcl_UtfPrev(s + 6, s));
    PutStr("utfprev start", Tcl_UtfPrev(s, s));
    p = Tcl_UtfFindFirst("abcabc", 'b');
    PutInt("utffindfirst", p ? p - "abcabc" : -1);
    s = "x\xe4\xb8\xady\xe4\xb8\xadz";
    p = Tcl_UtfFindLast(s, 0x4e2d);
    PutInt("utffindlast", p ? (int)(p - s) : -1);
    p = Tcl_UtfFindFirst(s, 'q');
    PutInt("utffindfirst none", p ? (int)(p - s) : -1);
    strcpy(buf, "Hello W\xc3\x89rld");
    n = Tcl_UtfToLower(buf);
    Put("utftolower", Tcl_ObjPrintf("%d %s", n, buf));
    n = Tcl_UtfToUpper(buf);
    Put("utftoupper", Tcl_ObjPrintf("%d %s", n, buf));
    strcpy(buf, "hELLO wORLD");
    n = Tcl_UtfToTitle(buf);
    Put("utftotitle", Tcl_ObjPrintf("%d %s", n, buf));
    PutInt("utfncmp eq", Tcl_UtfNcmp("abcdef", "abcxyz", 3));
    PutInt("utfncmp lt", Tcl_UtfNcmp("abc", "abd", 3) < 0);
    PutInt("utfncmp short", Tcl_UtfNcmp("ab", "abc", 3) < 0);
    PutInt("utfncasecmp", Tcl_UtfNcasecmp("HeLLo", "hello", 5));
    PutInt("utfncasecmp ne", Tcl_UtfNcasecmp("abc", "ABD", 3) < 0);

    /* Tcl_UniChar arrays. */
    PutInt("unicharlen", Tcl_UniCharLen(abc));
    Tcl_DStringInit(&ds);
    s = Tcl_UniCharToUtfDString(abc, 4, &ds);
    PutHex("unichartoutfdstring", s, Tcl_DStringLength(&ds));
    Tcl_DStringFree(&ds);
    Tcl_DStringInit(&ds);
    u = Tcl_UtfToUniCharDString("a\xc3\xa9\xe4\xb8\xad", -1, &ds);
    PutUni("utftounichardstring", u, Tcl_UniCharLen(u));
    PutInt("utftounichardstring len", Tcl_DStringLength(&ds));
    Tcl_DStringFree(&ds);
    {
        static const Tcl_UniChar x[] = { 'a', 'B', 'c', 0 }, y[] = { 'a', 'b', 'C', 0 };
        static const Tcl_UniChar pat[] = { 'a', '*', 'C', 0 };
        PutInt("unicharncmp", Tcl_UniCharNcmp(x, y, 3) < 0);
        PutInt("unicharncmp first", Tcl_UniCharNcmp(x, y, 1));
        PutInt("unicharncasecmp", Tcl_UniCharNcasecmp(x, y, 3));
        PutInt("unicharcasematch", Tcl_UniCharCaseMatch(x, pat, 0) * 10 + Tcl_UniCharCaseMatch(x, pat, 1));
    }

    /* Classes and case maps. */
    {
        static const int cs[] = { 'a', 'Z', '5', ' ', '\t', '_', '!', 0x7f, 0xe9, 0xc9, 0x4e2d, 0x3b1, 0x2028, 0 };
        o = Tcl_NewObj();
        for (i = 0; cs[i]; i++) {
            int c = cs[i];
            Tcl_AppendPrintfToObj(o, "%s%x:%d%d%d%d%d%d%d%d%d%d%d:%x/%x/%x", i ? " " : "", c,
                Tcl_UniCharIsAlnum(c), Tcl_UniCharIsAlpha(c), Tcl_UniCharIsDigit(c),
                Tcl_UniCharIsLower(c), Tcl_UniCharIsUpper(c), Tcl_UniCharIsSpace(c),
                Tcl_UniCharIsWordChar(c), Tcl_UniCharIsControl(c), Tcl_UniCharIsGraph(c),
                Tcl_UniCharIsPrint(c), Tcl_UniCharIsPunct(c),
                Tcl_UniCharToLower(c), Tcl_UniCharToUpper(c), Tcl_UniCharToTitle(c));
        }
        Put("classes", o);
    }

    /* Matches. */
    PutInt("stringmatch", Tcl_StringMatch("hello.c", "*.c"));
    PutInt("stringmatch no", Tcl_StringMatch("hello.h", "*.c"));
    PutInt("stringmatch class", Tcl_StringMatch("b7", "\\[a-c\\]?"));
    PutInt("stringmatch brackets", Tcl_StringMatch("b7", "[a-c][0-9]"));
    PutInt("stringcasematch", Tcl_StringCaseMatch("HELLO", "h*o", 1));
    PutInt("stringcasematch exact", Tcl_StringCaseMatch("HELLO", "h*o", 0));

    /* Backslashes. */
    n = Tcl_UtfBackslash("\\n rest", &rd, buf);
    Put("utfbackslash n", Tcl_ObjPrintf("%d %d %02x", n, rd, (unsigned char)buf[0]));
    n = Tcl_UtfBackslash("\\u4e2dx", &rd, buf);
    buf[n] = 0;
    Put("utfbackslash u", Tcl_ObjPrintf("%d %d %s", n, rd, buf));
    n = Tcl_UtfBackslash("\\x41", &rd, buf);
    Put("utfbackslash x", Tcl_ObjPrintf("%d %d %c", n, rd, buf[0]));
    n = Tcl_UtfBackslash("\\101z", &rd, buf);
    Put("utfbackslash octal", Tcl_ObjPrintf("%d %d %c", n, rd, buf[0]));
    n = Tcl_UtfBackslash("\\q", &rd, buf);
    Put("utfbackslash other", Tcl_ObjPrintf("%d %d %c", n, rd, buf[0]));
    Put("backslash", Tcl_ObjPrintf("%d", Tcl_Backslash("\\t", &rd)));
    PutInt("backslash read", rd);
    Put("backslash high", Tcl_ObjPrintf("%d", (unsigned char)Tcl_Backslash("\\xe9", NULL)));

    /* Tcl_PrintDouble. */
    Tcl_PrintDouble(interp, 0.1, buf); PutStr("printdouble", buf);
    Tcl_PrintDouble(interp, 1e300, buf); PutStr("printdouble big", buf);
    Tcl_PrintDouble(interp, 3.0, buf); PutStr("printdouble int", buf);
    Tcl_PrintDouble(interp, -1.0/3.0, buf); PutStr("printdouble third", buf);

    /* The Unicode form of an object. */
    o = Tcl_NewUnicodeObj(abc, -1);
    Tcl_IncrRefCount(o);
    PutInt("newunicode length", Tcl_GetCharLength(o));
    s = Tcl_GetString(o);
    PutHex("newunicode text", s, o->length);
    PutInt("getunichar", Tcl_GetUniChar(o, 2));
    Put("getrange", Tcl_GetRange(o, 1, 2));
    Put("getrange clamp", Tcl_GetRange(o, -3, 99));
    Put("getrange empty", Tcl_GetRange(o, 3, 1));
    Tcl_DecrRefCount(o);
    o = Tcl_NewStringObj("x\xc3\xa9y", -1);
    u = Tcl_GetUnicodeFromObj(o, &n);
    PutUni("getunicodefromobj", u, n);
    u = Tcl_GetUnicode(o);
    PutInt("getunicode end", u[3]);
    Tcl_AppendUnicodeToObj(o, abc + 1, 2);
    Put("appendunicode", o);
    PutInt("appendunicode length", Tcl_GetCharLength(o));
    Tcl_SetUnicodeObj(o, abc, 2);
    Put("setunicode", o);
    o = Tcl_NewIntObj(42);
    PutInt("getunichar int", Tcl_GetUniChar(o, 1));
    Tcl_AppendToObj(o, "x", 1);
    Put("unicode then append", o);

    Tcl_SetObjResult(interp, out);
    Tcl_DecrRefCount(out);
    return TCL_ERROR;
}
