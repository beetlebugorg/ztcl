/* The test package of the shared core of objects and results
 * (src/cext/obj.zig). Cxcore_Init builds a list of an int, a double,
 * a string, and the error message of a Get slot. The init gives the
 * list as the result and fails, so the script reads the list as the
 * error message of load.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <string.h>
#include <tcl.h>

#define CHECK(c) do { if (!(c)) { Tcl_SetResult(interp, (char *)#c, TCL_STATIC); return TCL_ERROR; } } while (0)

int Cxcore_Init(Tcl_Interp *interp) {
    Tcl_Obj *l, *o, **elems;
    int n, i;
    double d;
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    l = Tcl_NewListObj(0, NULL);
    Tcl_ListObjAppendElement(interp, l, Tcl_NewIntObj(42));
    Tcl_ListObjAppendElement(interp, l, Tcl_NewDoubleObj(0.1));
    Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj("a b", -1));
    CHECK(Tcl_ListObjGetElements(interp, l, &n, &elems) == TCL_OK && n == 3);
    CHECK(Tcl_GetIntFromObj(interp, elems[0], &i) == TCL_OK && i == 42);
    CHECK(Tcl_GetDoubleFromObj(interp, elems[1], &d) == TCL_OK && d == 0.1);
    o = Tcl_NewStringObj("12x", -1);
    Tcl_IncrRefCount(o);
    CHECK(Tcl_GetIntFromObj(interp, o, &i) == TCL_ERROR);
    /* The error message of the Get slot is the result now. */
    Tcl_ListObjAppendElement(interp, l, Tcl_GetObjResult(interp));
    Tcl_DecrRefCount(o);
    Tcl_SetObjResult(interp, l);
    return TCL_ERROR;
}
