/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include "tpersist_script.h"
#ifdef USE_NAVISERVER
#include <ns.h>
#endif

int Tpersist_Init(Tcl_Interp *interp) {
#if TCL_MAJOR_VERSION >= 9
    const char *minimum="9.0";
#else
    const char *minimum="8.6";
#endif
    if(!Tcl_InitStubs(interp,minimum,0)) return TCL_ERROR;
    if(Tcl_PkgPresent(interp,"tpersist",NULL,0)) return TCL_OK;
    Tcl_ResetResult(interp);
    if(!Tcl_CreateNamespace(interp,"::tpersist",NULL,NULL)) return TCL_ERROR;
    static const char *commands[]={"col","table","star","null","value","param",
        "eq","ne","lt","le","gt","ge","like","add","sub","mul","div",
        "in","not_in","and","or","not","is_null","is_not_null","asc","desc",
        "sum","avg","min","max","count","alias","select","insert","update","delete",
        "where","having","order_by","group_by","returning","limit","offset","distinct",
        "values","join","clear",NULL};
    for(int i=0;commands[i];i++) {
        char name[80]; snprintf(name,sizeof(name),"::tpersist::db_%s",commands[i]);
        Tcl_CreateObjCommand(interp,name,TpBuilderCmd,(ClientData)commands[i],NULL);
    }
    Tcl_CreateObjCommand(interp,"::tpersist::db_compile",TpCompileCmd,NULL,NULL);
    Tcl_CreateObjCommand(interp,"::tpersist::db_expr",TpExprCmd,NULL,NULL);
    if(Tcl_EvalEx(interp,tpersist_script,-1,TCL_EVAL_GLOBAL)!=TCL_OK) {
        Tcl_Namespace *ns=Tcl_FindNamespace(interp,"::tpersist",NULL,TCL_GLOBAL_ONLY);
        if(ns) Tcl_DeleteNamespace(ns);
        return TCL_ERROR;
    }
    return Tcl_PkgProvide(interp,"tpersist",TPERSIST_VERSION);
}

#ifdef USE_NAVISERVER
NS_EXPORT int Ns_ModuleVersion=1;
static int initInterp(Tcl_Interp *interp,const void *arg) {
    (void)arg;
    return Tpersist_Init(interp);
}
NS_EXPORT int Ns_ModuleInit(const char *server,const char *module) {
    (void)module;
    Ns_TclRegisterTrace(server,initInterp,NULL,NS_TCL_TRACE_CREATE);
    return NS_OK;
}
#endif
