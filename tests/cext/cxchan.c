/* The test package of the channel slots. It defines the channel type
 * "mem", a channel on a buffer in memory, and the transform "rot13",
 * which stacks on any channel. The command cxchan runs the C calls of
 * the channel slots on a channel by its name.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tcl.h>
#ifndef __wasi__
#include <unistd.h>
#endif

typedef struct Mem {
    char *data;
    int len, cap, pos;
    int watch;     /* the last mask of the watch proc */
    int nonblock;  /* the mode of the last call of the block mode proc */
    int empty;     /* input gives EAGAIN at the end of the data */
    Tcl_Channel chan;
} Mem;

static int memCount;
static char closed[200];

static int MemClose(ClientData cd, Tcl_Interp *interp) {
    Mem *m = cd;
    (void)interp;
    snprintf(closed + strlen(closed), sizeof(closed) - strlen(closed), "[mem %d]", m->len);
    ckfree(m->data);
    ckfree((char *)m);
    return TCL_OK;
}

static int MemInput(ClientData cd, char *buf, int n, int *err) {
    Mem *m = cd;
    int k = m->len - m->pos;
    if (k <= 0 && m->empty) {
        *err = EAGAIN;
        return -1;
    }
    if (k > n) k = n;
    if (k < 0) k = 0;
    memcpy(buf, m->data + m->pos, k);
    m->pos += k;
    return k;
}

static int MemOutput(ClientData cd, const char *buf, int n, int *err) {
    Mem *m = cd;
    (void)err;
    if (m->pos + n > m->cap) {
        m->cap = (m->pos + n) * 2;
        m->data = ckrealloc(m->data, m->cap);
    }
    memcpy(m->data + m->pos, buf, n);
    m->pos += n;
    if (m->pos > m->len) m->len = m->pos;
    return n;
}

static Tcl_WideInt MemWideSeek(ClientData cd, Tcl_WideInt off, int mode, int *err) {
    Mem *m = cd;
    Tcl_WideInt p = mode == SEEK_SET ? off : mode == SEEK_CUR ? m->pos + off : m->len + off;
    if (p < 0 || p > m->len) {
        *err = EINVAL;
        return -1;
    }
    m->pos = (int)p;
    return p;
}

static int MemSeek(ClientData cd, long off, int mode, int *err) {
    return (int)MemWideSeek(cd, off, mode, err);
}

static int MemSetOption(ClientData cd, Tcl_Interp *interp, const char *name, const char *value) {
    Mem *m = cd;
    if (strcmp(name, "-empty") == 0) {
        m->empty = atoi(value);
        return TCL_OK;
    }
    return Tcl_BadChannelOption(interp, name, "empty");
}

static int MemGetOption(ClientData cd, Tcl_Interp *interp, const char *name, Tcl_DString *ds) {
    Mem *m = cd;
    char buf[32];
    if (name == NULL) {
        Tcl_DStringAppendElement(ds, "-size");
        snprintf(buf, sizeof buf, "%d", m->len);
        Tcl_DStringAppendElement(ds, buf);
        Tcl_DStringAppendElement(ds, "-empty");
        Tcl_DStringAppendElement(ds, m->empty ? "1" : "0");
        return TCL_OK;
    }
    if (strcmp(name, "-size") == 0) {
        snprintf(buf, sizeof buf, "%d", m->len);
        Tcl_DStringAppend(ds, buf, -1);
        return TCL_OK;
    }
    if (strcmp(name, "-empty") == 0) {
        Tcl_DStringAppend(ds, m->empty ? "1" : "0", -1);
        return TCL_OK;
    }
    return Tcl_BadChannelOption(interp, name, "size empty");
}

static void MemWatch(ClientData cd, int mask) {
    ((Mem *)cd)->watch = mask;
}

static int MemHandle(ClientData cd, int dir, ClientData *h) {
    (void)cd;
    (void)dir;
    (void)h;
    return TCL_ERROR;
}

static int MemBlock(ClientData cd, int mode) {
    ((Mem *)cd)->nonblock = mode;
    return 0;
}

static const Tcl_ChannelType memType = {
    "mem", TCL_CHANNEL_VERSION_5, MemClose, MemInput, MemOutput, MemSeek,
    MemSetOption, MemGetOption, MemWatch, MemHandle, NULL, MemBlock,
    NULL, NULL, MemWideSeek, NULL, NULL
};

/* The transform: each letter goes 13 places on, in both directions. */
typedef struct Rot {
    Tcl_Channel below;
} Rot;

static void Rotate(char *s, int n) {
    for (int i = 0; i < n; i++) {
        char c = s[i];
        if (c >= 'a' && c <= 'z') s[i] = 'a' + (c - 'a' + 13) % 26;
        else if (c >= 'A' && c <= 'Z') s[i] = 'A' + (c - 'A' + 13) % 26;
    }
}

static int RotClose(ClientData cd, Tcl_Interp *interp) {
    (void)interp;
    strcat(closed, "[rot13]");
    ckfree((char *)cd);
    return TCL_OK;
}

static int RotInput(ClientData cd, char *buf, int n, int *err) {
    Rot *r = cd;
    int k = Tcl_ReadRaw(r->below, buf, n);
    if (k < 0) {
        *err = Tcl_GetErrno();
        return -1;
    }
    Rotate(buf, k);
    return k;
}

static int RotOutput(ClientData cd, const char *buf, int n, int *err) {
    Rot *r = cd;
    char *t = ckalloc(n > 0 ? n : 1);
    memcpy(t, buf, n);
    Rotate(t, n);
    int k = Tcl_WriteRaw(r->below, t, n);
    ckfree(t);
    if (k < 0) *err = Tcl_GetErrno();
    return k;
}

static void RotWatch(ClientData cd, int mask) {
    (void)cd;
    (void)mask;
}

static int RotBlock(ClientData cd, int mode) {
    (void)cd;
    (void)mode;
    return 0;
}

static const Tcl_ChannelType rotType = {
    "rot13", TCL_CHANNEL_VERSION_5, RotClose, RotInput, RotOutput, NULL,
    NULL, NULL, RotWatch, MemHandle, NULL, RotBlock,
    NULL, NULL, NULL, NULL, NULL
};

static char fired[200];

static void Fire(ClientData cd, int mask) {
    snprintf(fired + strlen(fired), sizeof(fired) - strlen(fired), "[%s %d]", (char *)cd, mask);
}

static void OnClose(ClientData cd) {
    snprintf(closed + strlen(closed), sizeof(closed) - strlen(closed), "[handler %s]", (char *)cd);
}

#define CHECK(c) do { if (!(c)) { Tcl_SetObjResult(interp, Tcl_NewStringObj(#c, -1)); return TCL_ERROR; } } while (0)

static const char *const ops[] = {
    "open", "write", "wbytes", "read", "rbytes", "gets", "getsobj", "flush",
    "seek", "tell", "eof", "blocked", "cfg", "close", "info", "push", "pop",
    "raw", "std", "events", "ungets", "names", "closed", "file", "fd",
    "error", "same", "notify", NULL
};

static int Cxchan(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int op, mode = 0;
    Tcl_Channel ch = NULL;
    char buf[256];
    (void)cd;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "op ?chan? ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], ops, "op", 0, &op) != TCL_OK) return TCL_ERROR;
    const char *opname = ops[op];
    if (op != 0 && op != 18 && op != 21 && op != 22 && op != 23 && op != 24) {
        if (objc < 3) {
            Tcl_WrongNumArgs(interp, 2, objv, "chan ?arg ...?");
            return TCL_ERROR;
        }
        ch = Tcl_GetChannel(interp, Tcl_GetString(objv[2]), &mode);
        if (ch == NULL) return TCL_ERROR;
    }
    if (strcmp(opname, "open") == 0) {
        Mem *m = (Mem *)ckalloc(sizeof(Mem));
        memset(m, 0, sizeof *m);
        m->cap = 16;
        m->data = ckalloc(m->cap);
        snprintf(buf, sizeof buf, "mem%d", memCount++);
        int mask = TCL_READABLE | TCL_WRITABLE;
        if (objc > 2 && strcmp(Tcl_GetString(objv[2]), "r") == 0) mask = TCL_READABLE;
        m->chan = Tcl_CreateChannel(&memType, buf, m, mask);
        CHECK(Tcl_GetChannelInstanceData(m->chan) == m);
        CHECK(Tcl_GetChannelType(m->chan) == &memType);
        CHECK(Tcl_IsChannelRegistered(interp, m->chan) == 0);
        Tcl_RegisterChannel(interp, m->chan);
        CHECK(Tcl_IsChannelRegistered(interp, m->chan) == 1);
        CHECK(Tcl_IsChannelExisting(buf) == 1);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(m->chan), -1));
        return TCL_OK;
    }
    if (strcmp(opname, "write") == 0) {
        int n = Tcl_WriteChars(ch, Tcl_GetString(objv[3]), -1);
        if (n < 0) return TCL_ERROR;
        Tcl_SetObjResult(interp, Tcl_NewIntObj(n));
        return TCL_OK;
    }
    if (strcmp(opname, "wbytes") == 0) {
        int len;
        unsigned char *b = Tcl_GetByteArrayFromObj(objv[3], &len);
        int n = Tcl_Write(ch, (char *)b, len);
        n += Tcl_WriteObj(ch, Tcl_NewStringObj("+", 1));
        Tcl_SetObjResult(interp, Tcl_NewIntObj(n));
        return TCL_OK;
    }
    if (strcmp(opname, "read") == 0) {
        int n = -1;
        if (objc > 3 && Tcl_GetIntFromObj(interp, objv[3], &n) != TCL_OK) return TCL_ERROR;
        Tcl_Obj *o = Tcl_NewObj();
        int got = Tcl_ReadChars(ch, o, n, 0);
        if (got < 0) {
            Tcl_DecrRefCount(o);
            snprintf(buf, sizeof buf, "read failed: %s", Tcl_ErrnoMsg(Tcl_GetErrno()));
            Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
            return TCL_ERROR;
        }
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        Tcl_ListObjAppendElement(interp, l, Tcl_NewIntObj(got));
        Tcl_ListObjAppendElement(interp, l, o);
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (strcmp(opname, "rbytes") == 0) {
        int n;
        if (Tcl_GetIntFromObj(interp, objv[3], &n) != TCL_OK) return TCL_ERROR;
        char *b = ckalloc(n + 1);
        int got = Tcl_Read(ch, b, n);
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        Tcl_ListObjAppendElement(interp, l, Tcl_NewIntObj(got));
        Tcl_ListObjAppendElement(interp, l, Tcl_NewByteArrayObj((unsigned char *)b, got > 0 ? got : 0));
        ckfree(b);
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (strcmp(opname, "gets") == 0) {
        Tcl_DString ds;
        Tcl_DStringInit(&ds);
        int n = Tcl_Gets(ch, &ds);
        snprintf(buf, sizeof buf, "%d", n);
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(buf, -1));
        Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(Tcl_DStringValue(&ds), Tcl_DStringLength(&ds)));
        Tcl_ListObjAppendElement(interp, l, Tcl_NewIntObj(Tcl_Eof(ch)));
        Tcl_ListObjAppendElement(interp, l, Tcl_NewIntObj(Tcl_InputBlocked(ch)));
        Tcl_DStringFree(&ds);
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (strcmp(opname, "getsobj") == 0) {
        Tcl_Obj *o = Tcl_NewStringObj("<", 1);
        int n = Tcl_GetsObj(ch, o);
        Tcl_AppendToObj(o, ">", 1);
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        Tcl_ListObjAppendElement(interp, l, Tcl_NewIntObj(n));
        Tcl_ListObjAppendElement(interp, l, o);
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (strcmp(opname, "flush") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_Flush(ch)));
        return TCL_OK;
    }
    if (strcmp(opname, "seek") == 0) {
        Tcl_WideInt off;
        if (Tcl_GetWideIntFromObj(interp, objv[3], &off) != TCL_OK) return TCL_ERROR;
        const char *w = objc > 4 ? Tcl_GetString(objv[4]) : "start";
        int whence = strcmp(w, "current") == 0 ? SEEK_CUR : strcmp(w, "end") == 0 ? SEEK_END : SEEK_SET;
        Tcl_WideInt r = Tcl_Seek(ch, off, whence);
        Tcl_SetObjResult(interp, Tcl_NewWideIntObj(r));
        return TCL_OK;
    }
    if (strcmp(opname, "tell") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewWideIntObj(Tcl_Tell(ch)));
        return TCL_OK;
    }
    if (strcmp(opname, "eof") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_Eof(ch)));
        return TCL_OK;
    }
    if (strcmp(opname, "blocked") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_InputBlocked(ch)));
        return TCL_OK;
    }
    if (strcmp(opname, "cfg") == 0) {
        if (objc == 5) {
            if (Tcl_SetChannelOption(interp, ch, Tcl_GetString(objv[3]), Tcl_GetString(objv[4])) != TCL_OK) return TCL_ERROR;
            Tcl_SetObjResult(interp, Tcl_NewStringObj("set", -1));
            return TCL_OK;
        }
        Tcl_DString ds;
        Tcl_DStringInit(&ds);
        if (Tcl_GetChannelOption(interp, ch, objc > 3 ? Tcl_GetString(objv[3]) : NULL, &ds) != TCL_OK) {
            Tcl_DStringFree(&ds);
            return TCL_ERROR;
        }
        Tcl_DStringResult(interp, &ds);
        return TCL_OK;
    }
    if (strcmp(opname, "close") == 0) {
        Tcl_CreateCloseHandler(ch, OnClose, "a");
        Tcl_CreateCloseHandler(ch, OnClose, "b");
        Tcl_DeleteCloseHandler(ch, OnClose, "b");
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_UnregisterChannel(interp, ch)));
        return TCL_OK;
    }
    if (strcmp(opname, "info") == 0) {
        Tcl_Channel top = Tcl_GetTopChannel(ch);
        const Tcl_ChannelType *t = Tcl_GetChannelType(top);
        snprintf(buf, sizeof buf, "%s type=%s ver=%d mode=%d/%d in=%d out=%d size=%d shared=%d below=%s",
            Tcl_GetChannelName(ch), Tcl_ChannelName(t), (int)(size_t)Tcl_ChannelVersion(t), mode,
            Tcl_GetChannelMode(ch), Tcl_InputBuffered(ch), Tcl_OutputBuffered(ch),
            Tcl_GetChannelBufferSize(ch), Tcl_IsChannelShared(ch),
            Tcl_GetStackedChannel(top) ? Tcl_ChannelName(Tcl_GetChannelType(Tcl_GetStackedChannel(top))) : "-");
        CHECK(Tcl_ChannelInputProc(t) != NULL && Tcl_ChannelOutputProc(t) != NULL);
        CHECK(Tcl_ChannelBlockModeProc(t) != NULL && Tcl_ChannelWatchProc(t) != NULL);
        CHECK(Tcl_ChannelCloseProc(t) != NULL && Tcl_ChannelClose2Proc(t) == NULL);
        CHECK(Tcl_ChannelGetHandleProc(t) == MemHandle && Tcl_ChannelFlushProc(t) == NULL);
        CHECK(Tcl_ChannelHandlerProc(t) == NULL && Tcl_ChannelThreadActionProc(t) == NULL);
        CHECK(Tcl_ChannelTruncateProc(t) == NULL);
        if (t == &memType) {
            CHECK(Tcl_ChannelSeekProc(t) == MemSeek && Tcl_ChannelWideSeekProc(t) == MemWideSeek);
            CHECK(Tcl_ChannelSetOptionProc(t) == MemSetOption && Tcl_ChannelGetOptionProc(t) == MemGetOption);
        }
        Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
        return TCL_OK;
    }
    if (strcmp(opname, "push") == 0) {
        Rot *r = (Rot *)ckalloc(sizeof(Rot));
        r->below = ch;
        Tcl_Channel t = Tcl_StackChannel(interp, &rotType, r, Tcl_GetChannelMode(ch), ch);
        CHECK(t != NULL);
        r->below = Tcl_GetStackedChannel(t);
        CHECK(Tcl_GetTopChannel(ch) == t);
        CHECK(strcmp(Tcl_GetChannelName(t), Tcl_GetString(objv[2])) == 0);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(t), -1));
        return TCL_OK;
    }
    if (strcmp(opname, "pop") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_UnstackChannel(interp, Tcl_GetTopChannel(ch))));
        return TCL_OK;
    }
    if (strcmp(opname, "raw") == 0) {
        Tcl_Channel base = ch;
        while (Tcl_GetStackedChannel(base)) base = Tcl_GetStackedChannel(base);
        CHECK(Tcl_GetChannelType(base) == &memType);
        Mem *m = Tcl_GetChannelInstanceData(base);
        Tcl_SetObjResult(interp, Tcl_NewByteArrayObj((unsigned char *)m->data, m->len));
        return TCL_OK;
    }
    if (strcmp(opname, "std") == 0) {
        Tcl_Channel out = Tcl_GetStdChannel(TCL_STDOUT);
        CHECK(out != NULL);
        CHECK(Tcl_IsStandardChannel(out));
        Tcl_WriteChars(out, "from C: ", -1);
        Tcl_WriteObj(out, Tcl_NewStringObj("line", -1));
        Tcl_WriteChars(out, "\n", 1);
        Tcl_Flush(out);
        snprintf(buf, sizeof buf, "%d %d %d", Tcl_GetChannel(interp, "stdout", NULL) == out,
            Tcl_GetChannel(interp, "stderr", NULL) == Tcl_GetStdChannel(TCL_STDERR),
            Tcl_GetStdChannel(TCL_STDIN) != NULL);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
        return TCL_OK;
    }
    if (strcmp(opname, "notify") == 0) {
        int mask;
        if (objc != 4 || Tcl_GetIntFromObj(interp, objv[3], &mask) != TCL_OK) return TCL_ERROR;
        Tcl_NotifyChannel(ch, mask);
        return TCL_OK;
    }
    if (strcmp(opname, "events") == 0) {
        Mem *m = Tcl_GetChannelInstanceData(ch);
        fired[0] = 0;
        Tcl_CreateChannelHandler(ch, TCL_READABLE, Fire, "r");
        int w1 = m->watch;
        Tcl_CreateChannelHandler(ch, TCL_WRITABLE, Fire, "w");
        int w2 = m->watch;
        Tcl_NotifyChannel(ch, TCL_READABLE);
        Tcl_NotifyChannel(ch, TCL_WRITABLE | TCL_READABLE);
        Tcl_DeleteChannelHandler(ch, Fire, "r");
        int w3 = m->watch;
        Tcl_NotifyChannel(ch, TCL_READABLE | TCL_WRITABLE);
        Tcl_ClearChannelHandlers(ch);
        int w4 = m->watch;
        Tcl_NotifyChannel(ch, TCL_WRITABLE);
        snprintf(buf, sizeof buf, "%s watch %d %d %d %d", fired, w1, w2, w3, w4);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
        return TCL_OK;
    }
    if (strcmp(opname, "ungets") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_Ungets(ch, Tcl_GetString(objv[3]), (int)strlen(Tcl_GetString(objv[3])), objc > 4)));
        return TCL_OK;
    }
    if (strcmp(opname, "names") == 0) {
        if (Tcl_GetChannelNamesEx(interp, "mem*") != TCL_OK) return TCL_ERROR;
        Tcl_Obj *l = Tcl_GetObjResult(interp);
        Tcl_IncrRefCount(l);
        Tcl_ListObjAppendElement(interp, l = Tcl_DuplicateObj(l), Tcl_NewIntObj(Tcl_IsChannelExisting("nosuch")));
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }
    if (strcmp(opname, "closed") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(closed, -1));
        closed[0] = 0;
        return TCL_OK;
    }
    if (strcmp(opname, "file") == 0) {
        Tcl_Channel f = Tcl_OpenFileChannel(interp, Tcl_GetString(objv[2]), Tcl_GetString(objv[3]), 0644);
        if (f == NULL) return TCL_ERROR;
        Tcl_RegisterChannel(interp, f);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(f), -1));
        return TCL_OK;
    }
    if (strcmp(opname, "fd") == 0) {
        /* A file channel on a descriptor of a new file. */
#ifdef __wasi__
        CHECK(0 && "no dup in WASI");
#else
        FILE *fp = fopen(Tcl_GetString(objv[2]), "w+");
        CHECK(fp != NULL);
        Tcl_Channel f = Tcl_MakeFileChannel((ClientData)(size_t)dup(fileno(fp)), TCL_READABLE | TCL_WRITABLE);
        fclose(fp);
        Tcl_RegisterChannel(interp, f);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(f), -1));
        return TCL_OK;
#endif
    }
    if (strcmp(opname, "error") == 0) {
        Tcl_SetChannelError(ch, Tcl_NewStringObj("chan failed", -1));
        Tcl_Obj *e = NULL;
        Tcl_GetChannelError(ch, &e);
        CHECK(e != NULL);
        Tcl_GetChannelError(ch, &e);
        CHECK(e == NULL);
        Tcl_SetChannelErrorInterp(interp, Tcl_NewStringObj("interp failed", -1));
        Tcl_GetChannelErrorInterp(interp, &e);
        CHECK(e != NULL);
        Tcl_SetObjResult(interp, e);
        return TCL_OK;
    }
    if (strcmp(opname, "same") == 0) {
        Tcl_Channel b = Tcl_GetChannel(interp, Tcl_GetString(objv[3]), NULL);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(b == ch));
        return TCL_OK;
    }
    return TCL_ERROR;
}

int Cxchan_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxchan", Cxchan, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxchan", "1.0");
}
