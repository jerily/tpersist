/* SPDX-License-Identifier: MIT */
#ifndef TPERSIST_LIBRARY_H
#define TPERSIST_LIBRARY_H
#include <tcl.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifdef BUILD_tpersist
#undef TCL_STORAGE_CLASS
#define TCL_STORAGE_CLASS DLLEXPORT
#endif
EXTERN int Tpersist_Init(Tcl_Interp *interp);
#ifdef __cplusplus
}
#endif
#endif
