/* SPDX-License-Identifier: MIT */
#ifndef TPERSIST_INTERNAL_H
#define TPERSIST_INTERNAL_H
#include "library.h"
#include <string.h>
#include <stdio.h>
#include <limits.h>
#if TCL_MAJOR_VERSION < 9
typedef int TpSize;
#else
typedef Tcl_Size TpSize;
#endif
typedef struct {
    Tcl_Interp *interp;
    Tcl_Obj *arena;
} TpContext;
static inline Tcl_Obj *TpOwn(TpContext *c, Tcl_Obj *o) {
    Tcl_ListObjAppendElement(NULL, c->arena, o);
    return o;
}
static inline Tcl_Obj *TpStr(TpContext *c, const char *s) { return TpOwn(c, Tcl_NewStringObj(s, -1)); }
static inline Tcl_Obj *TpDict(TpContext *c) { return TpOwn(c, Tcl_NewDictObj()); }
static inline Tcl_Obj *TpList(TpContext *c) { return TpOwn(c, Tcl_NewListObj(0, NULL)); }
static inline Tcl_Obj *TpInt(TpContext *c, Tcl_WideInt n) { return TpOwn(c, Tcl_NewWideIntObj(n)); }
static inline void TpPut(TpContext *c, Tcl_Obj *d, const char *key, Tcl_Obj *v) {
    Tcl_DictObjPut(NULL, d, TpStr(c, key), v);
}
static inline Tcl_Obj *TpGet(TpContext *c, Tcl_Obj *d, const char *key) {
    Tcl_Obj *v = NULL;
    if (Tcl_DictObjGet(c->interp, d, TpStr(c, key), &v) != TCL_OK) return NULL;
    return v;
}
static inline int TpError(TpContext *c, const char *code, const char *message) {
    Tcl_SetObjResult(c->interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(c->interp, "TPERSIST", code, NULL);
    return TCL_ERROR;
}
static inline Tcl_Obj *TpNode(TpContext *c, const char *node) {
    Tcl_Obj *d = TpDict(c);
    TpPut(c, d, "node", TpStr(c, node));
    return d;
}
int TpIsNode(Tcl_Obj *o);
int TpWideInt(TpContext *c, Tcl_Obj *o, Tcl_WideInt *value);
Tcl_Obj *TpColumn(TpContext *c, Tcl_Obj *o);
Tcl_Obj *TpTable(TpContext *c, Tcl_Obj *o);
int TpBuilderCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]);
int TpCompileCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]);
enum { TP_PROJECTION=1, TP_ORDERING=2, TP_STAR=4 };
typedef enum {
    TP_PARSE_SINGLE, TP_PARSE_PREDICATE, TP_PARSE_COLUMNS, TP_PARSE_ORDER, TP_PARSE_GROUP
} TpParseMode;
int TpCheckExpression(TpContext *c, Tcl_Obj *expression, int flags);
int TpParseExpression(TpContext *c, Tcl_Obj *source, TpParseMode mode, Tcl_Obj **result);
int TpExprCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]);
#endif
