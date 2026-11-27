/* The test package of the encodings and the regular expressions of the
 * area strings. Cxenc_Init appends each result to a list and gives the
 * list as the error message of load.
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

static Tcl_Obj *Hex(const char *s, int n) {
    Tcl_Obj *o = Tcl_NewObj();
    int i;
    for (i = 0; i < n; i++) Tcl_AppendPrintfToObj(o, "%02x", (unsigned char)s[i]);
    return o;
}

/* Converts with Tcl_ExternalToUtf or Tcl_UtfToExternal and shows the
 * code, the counts, and the bytes of the destination. */
static void Conv(Tcl_Interp *interp, const char *label, int to, const char *enc, const char *src, int len, int flags, int dstLen) {
    char dst[64];
    int rd = -1, wr = -1, ch = -1, rc;
    Tcl_EncodingState st = NULL;
    Tcl_Encoding e = Tcl_GetEncoding(interp, enc);
    memset(dst, 0x55, sizeof dst);
    if (to)
        rc = Tcl_ExternalToUtf(interp, e, src, len, flags, (flags & 3) == 3 ? NULL : &st, dst, dstLen, &rd, &wr, &ch);
    else
        rc = Tcl_UtfToExternal(interp, e, src, len, flags, (flags & 3) == 3 ? NULL : &st, dst, dstLen, &rd, &wr, &ch);
    Put(label, Tcl_ObjPrintf("rc %d read %d wrote %d chars %d %s", rc, rd, wr, ch, Tcl_GetString(Hex(dst, wr + 2))));
    Tcl_FreeEncoding(e);
}

/* An encoding of the package: each byte is its value plus one. */
static int RotTo(ClientData cd, const char *src, int srcLen, int flags, Tcl_EncodingState *st, char *dst, int dstLen, int *rd, int *wr, int *ch) {
    int i, n = srcLen < dstLen ? srcLen : dstLen;
    (void)cd; (void)flags; (void)st;
    for (i = 0; i < n; i++) dst[i] = (char)(src[i] - 1);
    *rd = n; *wr = n; *ch = n;
    return n < srcLen ? TCL_CONVERT_NOSPACE : TCL_OK;
}
static int RotFrom(ClientData cd, const char *src, int srcLen, int flags, Tcl_EncodingState *st, char *dst, int dstLen, int *rd, int *wr, int *ch) {
    int i, n = srcLen < dstLen ? srcLen : dstLen;
    (void)cd; (void)flags; (void)st;
    for (i = 0; i < n; i++) dst[i] = (char)(src[i] + 1);
    *rd = n; *wr = n; *ch = n;
    return n < srcLen ? TCL_CONVERT_NOSPACE : TCL_OK;
}
static int freed = 0;
static void RotFree(ClientData cd) { (void)cd; freed++; }

static void Re(Tcl_Interp *interp, const char *label, const char *pat, const char *text, int skip) {
    Tcl_RegExp re = Tcl_RegExpCompile(interp, pat);
    Tcl_Obj *o;
    const char *s, *e;
    int rc, i;
    if (re == NULL) {
        Put(label, Tcl_ObjPrintf("compile error: %s", Tcl_GetStringResult(interp)));
        Tcl_ResetResult(interp);
        return;
    }
    rc = Tcl_RegExpExec(interp, re, text + skip, text);
    o = Tcl_ObjPrintf("%d", rc);
    for (i = 0; rc == 1 && i < 3; i++) {
        Tcl_RegExpRange(re, i, &s, &e);
        if (s == NULL) Tcl_AppendToObj(o, " -", -1);
        else Tcl_AppendPrintfToObj(o, " %d-%d", (int)(s - text), (int)(e - text));
    }
    Put(label, o);
}

static void ReObj(Tcl_Interp *interp, const char *label, const char *pat, int flags, const char *text, int offset, int eflags) {
    Tcl_Obj *p = Tcl_NewStringObj(pat, -1), *t = Tcl_NewStringObj(text, -1), *o;
    Tcl_RegExp re;
    Tcl_RegExpInfo info;
    int rc, i;
    Tcl_IncrRefCount(p);
    Tcl_IncrRefCount(t);
    re = Tcl_GetRegExpFromObj(interp, p, flags);
    if (re == NULL) {
        Put(label, Tcl_ObjPrintf("compile error: %s", Tcl_GetStringResult(interp)));
        Tcl_ResetResult(interp);
    } else {
        rc = Tcl_RegExpExecObj(interp, re, t, offset, -1, eflags);
        Tcl_RegExpGetInfo(re, &info);
        o = Tcl_ObjPrintf("%d nsubs %d", rc, info.nsubs);
        for (i = 0; rc == 1 && i <= info.nsubs; i++)
            Tcl_AppendPrintfToObj(o, " %ld-%ld", info.matches[i].start, info.matches[i].end);
        Put(label, o);
    }
    Tcl_DecrRefCount(p);
    Tcl_DecrRefCount(t);
}

int Cxenc_Init(Tcl_Interp *interp) {
    Tcl_DString ds;
    Tcl_Encoding e;
    Tcl_Obj *o;
    const char *s;
    int rc;
    static const Tcl_EncodingType rot = { "cxrot", RotTo, RotFrom, RotFree, NULL, 1 };
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    out = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(out);

    /* Names and lookups. */
    e = Tcl_GetEncoding(interp, "utf-8");
    Put("getencoding", Tcl_NewStringObj(Tcl_GetEncodingName(e), -1));
    Tcl_FreeEncoding(e);
    e = Tcl_GetEncoding(interp, "binary");
    Put("getencoding binary", Tcl_NewStringObj(e ? Tcl_GetEncodingName(e) : "(null)", -1));
    Tcl_FreeEncoding(e);
    e = Tcl_GetEncoding(interp, "no-such");
    Put("getencoding unknown", Tcl_ObjPrintf("%s %s", e ? "handle" : "null", Tcl_GetStringResult(interp)));
    Tcl_ResetResult(interp);
    Put("system", Tcl_NewStringObj(Tcl_GetEncodingName(NULL), -1));
    o = Tcl_NewStringObj("iso8859-1", -1);
    rc = Tcl_GetEncodingFromObj(interp, o, &e);
    Put("getencodingfromobj", Tcl_ObjPrintf("%d %s", rc, Tcl_GetEncodingName(e)));
    Tcl_FreeEncoding(e);
    s = Tcl_GetEncodingNameFromEnvironment(&ds);
    Put("fromenvironment", Tcl_NewStringObj(s, -1));
    Tcl_DStringFree(&ds);
    rc = Tcl_SetSystemEncoding(interp, "nope");
    Put("setsystem bad", Tcl_ObjPrintf("%d %s", rc, Tcl_GetStringResult(interp)));
    Tcl_ResetResult(interp);
    Tcl_GetEncodingNames(interp);
    o = Tcl_GetObjResult(interp);
    {
        int n, i, hits = 0;
        Tcl_Obj **v;
        Tcl_ListObjGetElements(NULL, o, &n, &v);
        for (i = 0; i < n; i++) {
            const char *x = Tcl_GetString(v[i]);
            if (!strcmp(x, "utf-8") || !strcmp(x, "iso8859-1") || !strcmp(x, "unicode") || !strcmp(x, "ascii") || !strcmp(x, "identity")) hits++;
        }
        Put("names", Tcl_NewIntObj(hits));
    }
    Tcl_ResetResult(interp);

    /* Conversions to UTF-8. */
    Conv(interp, "to utf-8", 1, "utf-8", "a\xc3\xa9", 3, 3, 64);
    Conv(interp, "to utf-8 nul", 1, "utf-8", "a\0b", 3, 3, 64);
    Conv(interp, "to utf-8 bad", 1, "utf-8", "a\xff", 2, 3, 64);
    Conv(interp, "to utf-8 partial", 1, "utf-8", "a\xc3", 2, TCL_ENCODING_START, 64);
    Conv(interp, "to utf-8 partial end", 1, "utf-8", "a\xc3", 2, 3, 64);
    Conv(interp, "to utf-8 stop", 1, "utf-8", "a\xff", 2, 3 | TCL_ENCODING_STOPONERROR, 64);
    Conv(interp, "to utf-8 nospace", 1, "utf-8", "abcdef", 6, 3, 4);
    Conv(interp, "to latin1", 1, "iso8859-1", "a\xe9\0", 3, 3, 64);
    Conv(interp, "to ascii", 1, "ascii", "a\x41", 2, 3, 64);
    Conv(interp, "to identity", 1, "identity", "a\xe9", 2, 3, 64);
    Conv(interp, "to unicode", 1, "unicode", "a\0\x2d\x4e", 4, 3, 64);
    Conv(interp, "to unicode odd", 1, "unicode", "a\0b", 3, TCL_ENCODING_START, 64);
    Conv(interp, "to no terminate", 1, "utf-8", "ab", 2, 3 | TCL_ENCODING_NO_TERMINATE, 2);

    /* Conversions from UTF-8. */
    Conv(interp, "from utf-8", 0, "utf-8", "a\xc0\x80\xc3\xa9", 5, 3, 64);
    Conv(interp, "from latin1", 0, "iso8859-1", "a\xc3\xa9\xe4\xb8\xad", -1, 3, 64);
    Conv(interp, "from latin1 stop", 0, "iso8859-1", "a\xe4\xb8\xad", -1, 3 | TCL_ENCODING_STOPONERROR, 64);
    Conv(interp, "from ascii", 0, "ascii", "a\xc3\xa9z", -1, 3, 64);
    Conv(interp, "from unicode", 0, "unicode", "a\xe4\xb8\xad", -1, 3, 64);
    Conv(interp, "from nospace", 0, "iso8859-1", "abcdef", -1, 3, 4);
    Conv(interp, "from partial", 0, "iso8859-1", "a\xc3", 2, TCL_ENCODING_START, 64);

    /* The DString forms. */
    e = Tcl_GetEncoding(interp, "iso8859-1");
    s = Tcl_ExternalToUtfDString(e, "caf\xe9", -1, &ds);
    Put("externaltoutfdstring", Tcl_ObjPrintf("%d %s", Tcl_DStringLength(&ds), s));
    Tcl_DStringFree(&ds);
    s = Tcl_UtfToExternalDString(e, "caf\xc3\xa9", -1, &ds);
    Put("utftoexternaldstring", Hex(s, Tcl_DStringLength(&ds)));
    Tcl_DStringFree(&ds);
    Tcl_FreeEncoding(e);
    {
        char big[600];
        int i;
        for (i = 0; i < 599; i++) big[i] = (char)('a' + i % 26);
        big[599] = 0;
        s = Tcl_UtfToExternalDString(NULL, big, -1, &ds);
        Put("dstring big", Tcl_ObjPrintf("%d %d", Tcl_DStringLength(&ds), (int)strlen(s)));
        Tcl_DStringFree(&ds);
    }
    e = Tcl_GetEncoding(interp, "unicode");
    s = Tcl_UtfToExternalDString(e, "hi", -1, &ds);
    Put("unicode dstring", Hex(s, Tcl_DStringLength(&ds) + 2));
    Tcl_DStringFree(&ds);
    s = Tcl_ExternalToUtfDString(e, "h\0i\0\0\0", -1, &ds);
    Put("unicode back", Tcl_ObjPrintf("%d %s", Tcl_DStringLength(&ds), s));
    Tcl_DStringFree(&ds);
    Tcl_FreeEncoding(e);

    /* An encoding of the package. */
    e = Tcl_CreateEncoding(&rot);
    s = Tcl_UtfToExternalDString(e, "HAL", -1, &ds);
    Put("created from", Tcl_NewStringObj(s, -1));
    Tcl_DStringFree(&ds);
    s = Tcl_ExternalToUtfDString(e, "IBM", -1, &ds);
    Put("created to", Tcl_NewStringObj(s, -1));
    Tcl_DStringFree(&ds);
    {
        Tcl_Encoding e2 = Tcl_GetEncoding(interp, "cxrot");
        Put("created lookup", Tcl_ObjPrintf("%d %s", e2 == e, Tcl_GetEncodingName(e2)));
        Tcl_FreeEncoding(e2);
    }
    Tcl_FreeEncoding(e);
    Put("created freed", Tcl_NewIntObj(freed));

    /* The default folder and the search path. */
    Tcl_SetDefaultEncodingDir("/enc/dir");
    Put("defaultdir", Tcl_NewStringObj(Tcl_GetDefaultEncodingDir(), -1));
    o = Tcl_NewStringObj("/a /b", -1);
    rc = Tcl_SetEncodingSearchPath(o);
    Put("searchpath", Tcl_ObjPrintf("%d %s", rc, Tcl_GetString(Tcl_GetEncodingSearchPath())));
    rc = Tcl_SetEncodingSearchPath(Tcl_NewStringObj("{bad", -1));
    Put("searchpath bad", Tcl_NewIntObj(rc));

    /* Regular expressions. */
    Tcl_SetObjResult(interp, Tcl_NewStringObj("kept", -1));
    Re(interp, "regexp", "b(c+)(x)?", "abccd", 0);
    Put("result kept", Tcl_NewStringObj(Tcl_GetStringResult(interp), -1));
    Tcl_ResetResult(interp);
    Re(interp, "regexp none", "z", "abc", 0);
    Re(interp, "regexp utf", "\xc3\xa9(.)", "a\xc3\xa9\xe4\xb8\xadz", 0);
    Re(interp, "regexp anchor", "^c", "abc", 2);
    Re(interp, "regexp anchor start", "^a", "abc", 0);
    Re(interp, "regexp skip", "b", "abcb", 2);
    Re(interp, "regexp bad", "a(", "abc", 0);
    Put("regexpmatch", Tcl_ObjPrintf("%d %d", Tcl_RegExpMatch(interp, "hello", "l+"), Tcl_RegExpMatch(interp, "hello", "^l")));
    rc = Tcl_RegExpMatch(interp, "x", "*");
    Put("regexpmatch bad", Tcl_ObjPrintf("%d %s", rc, Tcl_GetStringResult(interp)));
    Tcl_ResetResult(interp);
    ReObj(interp, "execobj", "(\\d+)-(\\d+)", TCL_REG_ADVANCED, "ab 12-345 x", 0, 0);
    ReObj(interp, "execobj offset", "^(\\w)", TCL_REG_ADVANCED, "ab cd", 3, 0);
    ReObj(interp, "execobj notbol", "^(\\w)", TCL_REG_ADVANCED, "ab cd", 3, TCL_REG_NOTBOL);
    ReObj(interp, "execobj nocase", "AB", TCL_REG_ADVANCED | TCL_REG_NOCASE, "xab", 0, 0);
    ReObj(interp, "execobj quote", "a.b", TCL_REG_QUOTE, "axb a.b", 0, 0);
    ReObj(interp, "execobj extended", "a+(b)", TCL_REG_EXTENDED, "caab", 0, 0);
    ReObj(interp, "execobj expanded", "a b # c", TCL_REG_ADVANCED | TCL_REG_EXPANDED, "xab", 0, 0);
    ReObj(interp, "execobj newline", "^b", TCL_REG_ADVANCED | TCL_REG_NEWLINE, "a\nb", 0, 0);
    ReObj(interp, "execobj none", "q", TCL_REG_ADVANCED, "abc", 0, 0);
    {
        Tcl_Obj *t = Tcl_NewStringObj("abc", -1), *p = Tcl_NewStringObj("b", -1), *q = Tcl_NewStringObj("(", -1);
        Tcl_IncrRefCount(t); Tcl_IncrRefCount(p); Tcl_IncrRefCount(q);
        Put("matchobj", Tcl_ObjPrintf("%d", Tcl_RegExpMatchObj(interp, t, p)));
        rc = Tcl_RegExpMatchObj(interp, t, q);
        Put("matchobj bad", Tcl_ObjPrintf("%d %s", rc, Tcl_GetStringResult(interp)));
        Tcl_ResetResult(interp);
        Tcl_DecrRefCount(t); Tcl_DecrRefCount(p); Tcl_DecrRefCount(q);
    }

    Tcl_SetObjResult(interp, out);
    Tcl_DecrRefCount(out);
    return TCL_ERROR;
}
