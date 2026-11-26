/* The stub library of the native spike (docs/dev/cext-tasks/, task 01).
   Tcl_InitStubs reads the real table of the interp and gives the
   extension a copy whose slots are trampolines of tramp.S. Each
   trampoline counts its slot and jumps to the real function. At exit,
   the counts go to the file of $RECSTUB_OUT.
   SPDX-License-Identifier: BSD-2-Clause */
#include <tcl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "slots.h"

const TclStubs *tclStubsPtr;
const TclPlatStubs *tclPlatStubsPtr; const void *tclIntStubsPtr, *tclIntPlatStubsPtr;

struct hooks { const void *plat, *intern, *intplat; };
struct head { int magic; const void *hooks; };
struct interp_head { char *r; void *f; int e; const TclStubs *stubs; };

static void *wrap(const void *real, int n, void *const *tramp, void **reals) {
    if (!real) return NULL;
    size_t sz = sizeof(struct head) + n * sizeof(void *);
    struct head *copy = malloc(sz);
    memcpy(copy, real, sz);
    void **src = (void **)((char *)real + sizeof(struct head));
    void **dst = (void **)((char *)copy + sizeof(struct head));
    for (int i = 0; i < n; i++) { reals[i] = src[i]; dst[i] = src[i] ? tramp[i] : NULL; }
    return copy;
}

const char *Tcl_InitStubs(Tcl_Interp *interp, const char *version, int exact) {
    const TclStubs *real = ((struct interp_head *)interp)->stubs;
    if (!real || real->magic != TCL_STUB_MAGIC) return NULL;
    const struct hooks *rh = (const struct hooks *)real->hooks;
    struct hooks *h = malloc(sizeof *h);
    h->plat = wrap(rh ? rh->plat : NULL, N_plat, rec_t_plat, rec_real_plat);
    h->intern = wrap(rh ? rh->intern : NULL, N_int, rec_t_int, rec_real_int);
    h->intplat = wrap(rh ? rh->intplat : NULL, N_intplat, rec_t_intplat, rec_real_intplat);
    struct head *pub = wrap(real, N_pub, rec_t_pub, rec_real_pub);
    pub->hooks = h;
    tclStubsPtr = (const TclStubs *)pub;
    tclPlatStubsPtr = (const TclPlatStubs *)h->plat; tclIntStubsPtr = h->intern; tclIntPlatStubsPtr = h->intplat;
    const char *got = tclStubsPtr->tcl_PkgRequireEx(interp, "Tcl", version, 0, NULL);
    if (got && exact && strcmp(got, version) != 0) return NULL;
    return got;
}

static void dump(const char *k, int n, unsigned long *c) {
    const char *path = getenv("RECSTUB_OUT");
    if (!path) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    for (int i = 0; i < n; i++) if (c[i]) fprintf(f, "%s\t%d\t%lu\n", k, i, c[i]);
    fclose(f);
}

__attribute__((destructor)) static void rec_fini(void) {
    dump("pub", N_pub, rec_cnt_pub);
    dump("int", N_int, rec_cnt_int);
    dump("intplat", N_intplat, rec_cnt_intplat);
}
