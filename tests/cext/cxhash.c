/* The test package of the hash table and assoc data slots. The command
 * cxhash runs one group of checks. A failed check gives an error with
 * its text.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdio.h>
#include <string.h>
#include <tcl.h>

#define CHECK(c) do { if (!(c)) { Tcl_SetObjResult(interp, Tcl_NewStringObj(#c, -1)); return TCL_ERROR; } } while (0)

static int dropped;

static void Drop(ClientData cd, Tcl_Interp *interp) {
    (void)interp;
    dropped += (int)(size_t)cd;
}

/* A custom key type: keys are C strings that compare with no case. */
static unsigned int NoCaseHash(Tcl_HashTable *t, void *key) {
    const char *s = key;
    unsigned int h = 0;
    (void)t;
    for (; *s; s++) h = h * 31 + (unsigned char)(*s | 0x20);
    return h;
}

static int NoCaseCompare(void *key, Tcl_HashEntry *e) {
    const char *a = key, *b = e->key.oneWordValue;
    for (; *a && *b; a++, b++) if ((*a | 0x20) != (*b | 0x20)) return 0;
    return *a == *b;
}

static Tcl_HashEntry *NoCaseAlloc(Tcl_HashTable *t, void *key) {
    Tcl_HashEntry *e = (Tcl_HashEntry *)ckalloc(sizeof(Tcl_HashEntry));
    (void)t;
    e->key.oneWordValue = key;
    e->clientData = NULL;
    return e;
}

static int freedCustom;

static void NoCaseFree(Tcl_HashEntry *e) {
    freedCustom++;
    ckfree((char *)e);
}

static const Tcl_HashKeyType noCaseType = {
    TCL_HASH_KEY_TYPE_VERSION, 0, NoCaseHash, NoCaseCompare, NoCaseAlloc, NoCaseFree
};

static int Strings(Tcl_Interp *interp) {
    Tcl_HashTable t;
    Tcl_HashSearch s;
    Tcl_HashEntry *e;
    char key[32];
    int i, isNew, n = 0, sum = 0;
    char *stats;
    Tcl_InitHashTable(&t, TCL_STRING_KEYS);
    for (i = 0; i < 1000; i++) {
        sprintf(key, "key%d", i);
        e = Tcl_CreateHashEntry(&t, key, &isNew);
        CHECK(isNew);
        Tcl_SetHashValue(e, (ClientData)(size_t)i);
    }
    CHECK(t.numEntries == 1000);
    e = Tcl_CreateHashEntry(&t, "key5", &isNew);
    CHECK(!isNew && (size_t)Tcl_GetHashValue(e) == 5);
    CHECK(strcmp(Tcl_GetHashKey(&t, e), "key5") == 0);
    CHECK(Tcl_FindHashEntry(&t, "key999") != NULL);
    CHECK(Tcl_FindHashEntry(&t, "key1000") == NULL);
    for (e = Tcl_FirstHashEntry(&t, &s); e != NULL; e = Tcl_NextHashEntry(&s)) {
        n++;
        sum += (int)(size_t)Tcl_GetHashValue(e);
        if ((size_t)Tcl_GetHashValue(e) % 3 == 0) Tcl_DeleteHashEntry(e);
    }
    CHECK(n == 1000 && sum == 499500);
    CHECK(t.numEntries == 666);
    CHECK(Tcl_FindHashEntry(&t, "key3") == NULL);
    stats = Tcl_HashStats(&t);
    CHECK(strncmp(stats, "666 entries in table, ", 22) == 0);
    ckfree(stats);
    Tcl_DeleteHashTable(&t);
    return TCL_OK;
}

static int Words(Tcl_Interp *interp) {
    Tcl_HashTable t;
    Tcl_HashEntry *e;
    int a[3] = {1, 2, 3}, b[3] = {1, 2, 3}, c[3] = {3, 2, 1}, isNew;
    static int x, y;
    Tcl_InitHashTable(&t, 3);
    e = Tcl_CreateHashEntry(&t, (char *)a, &isNew);
    CHECK(isNew);
    CHECK(Tcl_FindHashEntry(&t, (char *)b) == e);
    CHECK(Tcl_FindHashEntry(&t, (char *)c) == NULL);
    CHECK(memcmp(Tcl_GetHashKey(&t, e), b, sizeof b) == 0);
    Tcl_DeleteHashTable(&t);
    Tcl_InitHashTable(&t, TCL_ONE_WORD_KEYS);
    e = Tcl_CreateHashEntry(&t, (char *)&x, &isNew);
    CHECK(isNew && Tcl_GetHashKey(&t, e) == (void *)&x);
    CHECK(Tcl_FindHashEntry(&t, (char *)&y) == NULL);
    Tcl_DeleteHashEntry(e);
    CHECK(t.numEntries == 0);
    Tcl_DeleteHashTable(&t);
    return TCL_OK;
}

static int Objs(Tcl_Interp *interp) {
    Tcl_HashTable t;
    Tcl_HashEntry *e;
    Tcl_Obj *k = Tcl_NewStringObj("alpha", -1), *same = Tcl_NewStringObj("alpha", -1);
    int isNew;
    Tcl_IncrRefCount(k);
    Tcl_IncrRefCount(same);
    Tcl_InitObjHashTable(&t);
    e = Tcl_CreateHashEntry(&t, (char *)k, &isNew);
    CHECK(isNew);
    CHECK(k->refCount == 2);
    CHECK(Tcl_FindHashEntry(&t, (char *)same) == e);
    CHECK(Tcl_GetHashKey(&t, e) == (void *)k);
    Tcl_DeleteHashTable(&t);
    CHECK(k->refCount == 1);
    Tcl_DecrRefCount(k);
    Tcl_DecrRefCount(same);
    return TCL_OK;
}

static int Custom(Tcl_Interp *interp) {
    Tcl_HashTable t;
    Tcl_HashEntry *e;
    int isNew;
    freedCustom = 0;
    Tcl_InitCustomHashTable(&t, TCL_CUSTOM_PTR_KEYS, &noCaseType);
    e = Tcl_CreateHashEntry(&t, "Hello", &isNew);
    CHECK(isNew);
    CHECK(Tcl_FindHashEntry(&t, "hELLO") == e);
    Tcl_CreateHashEntry(&t, "HELLO", &isNew);
    CHECK(!isNew);
    Tcl_CreateHashEntry(&t, "world", &isNew);
    CHECK(isNew && t.numEntries == 2);
    Tcl_DeleteHashTable(&t);
    CHECK(freedCustom == 2);
    return TCL_OK;
}

static int Assoc(Tcl_Interp *interp) {
    Tcl_InterpDeleteProc *proc = NULL;
    dropped = 0;
    Tcl_SetAssocData(interp, "cxhash-a", Drop, (ClientData)1);
    Tcl_SetAssocData(interp, "cxhash-b", Drop, (ClientData)10);
    Tcl_SetAssocData(interp, "cxhash-a", Drop, (ClientData)100);
    CHECK((size_t)Tcl_GetAssocData(interp, "cxhash-a", &proc) == 100 && proc == Drop);
    CHECK(Tcl_GetAssocData(interp, "cxhash-none", NULL) == NULL);
    Tcl_DeleteAssocData(interp, "cxhash-b");
    CHECK(dropped == 10);
    Tcl_DeleteAssocData(interp, "cxhash-a");
    CHECK(dropped == 110);
    CHECK(Tcl_GetAssocData(interp, "cxhash-a", NULL) == NULL);
    return TCL_OK;
}

/* The create proc with no flag pointer finds and does not add, as in
 * Tcl 8.6. NaviServer calls it so. */
static int Lookup(Tcl_Interp *interp) {
    Tcl_HashTable t;
    Tcl_HashEntry *a, *b, *c;
    int isNew;
    Tcl_InitHashTable(&t, TCL_STRING_KEYS);
    a = (*t.createProc)(&t, "absent", NULL);
    b = Tcl_CreateHashEntry(&t, "here", &isNew);
    Tcl_SetHashValue(b, (ClientData) "v");
    c = (*t.createProc)(&t, "here", NULL);
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %d %d %s", a == NULL, t.numEntries, c == b, (char *) Tcl_GetHashValue(c)));
    Tcl_DeleteHashTable(&t);
    return TCL_OK;
}

static int Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    static const char *const names[] = {"strings", "words", "objs", "custom", "assoc", "lookup", NULL};
    int i;
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "group");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], names, "group", 0, &i) != TCL_OK) return TCL_ERROR;
    switch (i) {
    case 0: return Strings(interp);
    case 1: return Words(interp);
    case 2: return Objs(interp);
    case 3: return Custom(interp);
    case 4: return Assoc(interp);
    default: return Lookup(interp);
    }
}

int Cxhash_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "cxhash", Cmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "cxhash", "1.0");
}
