/* SPDX-License-Identifier: MIT */
#include "internal.h"
#if TCL_MAJOR_VERSION < 9
#include <tclTomMath.h>
#endif

/* Tcl 8.6's wide conversion can truncate a bignum. Canonicalize through the
 * public bignum API and check the signed SQL integer range before converting.
 * Tcl_NewBignumObj takes ownership, including cleanup on every error path. */
int TpWideInt(TpContext *c, Tcl_Obj *o, Tcl_WideInt *value) {
#if TCL_MAJOR_VERSION >= 9
    return Tcl_GetWideIntFromObj(c->interp,o,value);
#else
    mp_int big;
    if (Tcl_GetBignumFromObj(c->interp,o,&big)!=TCL_OK) return TCL_ERROR;
    Tcl_Obj *canonical=TpOwn(c,Tcl_NewBignumObj(&big));
    const char *s=Tcl_GetString(canonical);
    int negative=*s=='-';
    if(negative) s++;
    size_t length=strlen(s);
    if(length>19 || (length==19 && strcmp(s,negative?"9223372036854775808":"9223372036854775807")>0))
        return TpError(c,"TYPE","integer is outside the signed 64-bit range");
    return Tcl_GetWideIntFromObj(c->interp,canonical,value);
#endif
}

int TpIsNode(Tcl_Obj *o) {
    Tcl_Obj *key = Tcl_NewStringObj("node", -1), *v = NULL;
    Tcl_IncrRefCount(key);
    int ok = Tcl_DictObjGet(NULL, o, key, &v) == TCL_OK && v != NULL;
    Tcl_DecrRefCount(key);
    return ok;
}

Tcl_Obj *TpColumn(TpContext *c, Tcl_Obj *o) {
    if (TpIsNode(o)) return o;
    Tcl_Obj *d = TpNode(c, "col");
    TpPut(c, d, "name", o);
    return d;
}

Tcl_Obj *TpTable(TpContext *c, Tcl_Obj *o) {
    if (TpIsNode(o)) return o;
    Tcl_Obj *d = TpNode(c, "table");
    Tcl_Obj *key=TpStr(c,"kind"), *kind=NULL;
    if (Tcl_DictObjGet(NULL,o,key,&kind)==TCL_OK && kind && !strcmp(Tcl_GetString(kind),"table_def")) {
        Tcl_Obj *name=TpGet(c,o,"name"), *schema=TpGet(c,o,"schema");
        if(name) {
            TpPut(c,d,"name",name);
            if(schema) TpPut(c,d,"schema",schema);
            return d;
        }
    }
    TpPut(c, d, "name", o);
    return d;
}

static int contains(const char *items, const char *item) {
    size_t n = strlen(item);
    const char *p = items;
    while (*p) {
        const char *end = strchr(p, ' ');
        size_t size = end ? (size_t)(end-p) : strlen(p);
        if (size == n && !memcmp(p, item, n)) return 1;
        p += size;
        if (*p) p++;
    }
    return 0;
}

static int build(TpContext *c, const char *cmd, int objc, Tcl_Obj *const v[], Tcl_Obj **out) {
    Tcl_Obj *d, *x, *kind;
    const char *k;
#define ARGS(lo,hi,usage) do { if (objc < (lo) || objc > (hi)) { Tcl_WrongNumArgs(c->interp,1,v,usage); return TCL_ERROR; } } while (0)
#define OPT(i) Tcl_GetString(v[i])
    if (!strcmp(cmd,"col") || !strcmp(cmd,"table")) {
        ARGS(2,6,"name ?-table qualifier? / name ?-schema schema? ?-as alias?");
        if (objc % 2 != 0) return TpError(c,"ARGS","options must be name/value pairs");
        d = TpNode(c,cmd); TpPut(c,d,"name",v[1]);
        for (int i=2;i<objc;i+=2) {
            const char *key = NULL;
            if (!strcmp(cmd,"col") && !strcmp(OPT(i),"-table")) key="table";
            if (!strcmp(cmd,"table") && !strcmp(OPT(i),"-schema")) key="schema";
            if (!strcmp(cmd,"table") && !strcmp(OPT(i),"-as")) key="alias";
            if (!key) return TpError(c,"ARGS","unknown identifier option");
            TpPut(c,d,key,v[i+1]);
        }
    } else if (!strcmp(cmd,"star")) {
        ARGS(1,2,"?table?"); d=TpNode(c,"star");
        if (objc==2) TpPut(c,d,"table",v[1]);
    } else if (!strcmp(cmd,"null")) {
        ARGS(1,1,""); d=TpNode(c,"null");
    } else if (!strcmp(cmd,"value") || !strcmp(cmd,"param")) {
        ARGS(2,4,"value ?-type type?");
        if (objc!=2 && (objc!=4 || strcmp(OPT(2),"-type"))) return TpError(c,"ARGS","expected -type type");
        d=TpNode(c,cmd);
        TpPut(c,d,!strcmp(cmd,"param")?"name":"value",v[1]);
        TpPut(c,d,"type",objc==4?v[3]:TpStr(c,"auto"));
    } else if (contains("eq ne lt le gt ge like add sub mul div",cmd)) {
        ARGS(3,3,"leftExpression rightExpression"); d=TpNode(c,cmd);
        TpPut(c,d,"left",v[1]); TpPut(c,d,"right",v[2]);
    } else if (!strcmp(cmd,"in") || !strcmp(cmd,"not_in")) {
        ARGS(3,3,"expression expressionList"); d=TpNode(c,cmd);
        TpPut(c,d,"expr",v[1]); TpPut(c,d,"items",v[2]);
    } else if (!strcmp(cmd,"and") || !strcmp(cmd,"or")) {
        ARGS(2,INT_MAX,"expression ?expression ...?"); d=TpNode(c,cmd);
        TpPut(c,d,"items",TpOwn(c,Tcl_NewListObj(objc-1,v+1)));
    } else if (contains("not is_null is_not_null asc desc sum avg min max",cmd)) {
        ARGS(2,2,"expression"); d=TpNode(c,cmd); TpPut(c,d,"expr",v[1]);
    } else if (!strcmp(cmd,"count")) {
        ARGS(1,2,"?expression?"); d=TpNode(c,cmd);
        TpPut(c,d,"expr",objc==2?v[1]:TpNode(c,"star"));
    } else if (!strcmp(cmd,"alias")) {
        ARGS(3,3,"expression name"); d=TpNode(c,cmd);
        TpPut(c,d,"expr",v[1]); TpPut(c,d,"name",v[2]);
    } else if (contains("select insert update delete",cmd)) {
        ARGS(2,4,"table ?-columns columnList?");
        if (objc!=2 && (strcmp(cmd,"select") || objc!=4 || strcmp(OPT(2),"-columns")))
            return TpError(c,"ARGS","only select accepts -columns");
        d=TpDict(c); TpPut(c,d,"version",TpInt(c,1)); TpPut(c,d,"kind",TpStr(c,cmd));
        TpPut(c,d,"table",TpTable(c,v[1]));
        if (!strcmp(cmd,"select")) {
            Tcl_Obj *cols=TpList(c);
            if (objc==4) {
                TpSize n; Tcl_Obj **items;
                if (Tcl_ListObjGetElements(c->interp,v[3],&n,&items)!=TCL_OK) return TCL_ERROR;
                if (!n) return TpError(c,"VALIDATION","select requires at least one column");
                for (TpSize i=0;i<n;i++) Tcl_ListObjAppendElement(NULL,cols,TpColumn(c,items[i]));
            } else Tcl_ListObjAppendElement(NULL,cols,TpNode(c,"star"));
            TpPut(c,d,"columns",cols);
        }
    } else {
        ARGS(2,INT_MAX,"statement ?arguments ...?");
        kind=TpGet(c,v[1],"kind"); x=TpGet(c,v[1],"version");
        int version;
        if (!kind || !x || Tcl_GetIntFromObj(NULL,x,&version)!=TCL_OK || version!=1)
            return TpError(c,"VALIDATION","expected a version 1 statement dictionary");
        k=Tcl_GetString(kind);
        if (!contains("select insert update delete",k)) return TpError(c,"VALIDATION","unknown statement kind");
        d=TpOwn(c,Tcl_DuplicateObj(v[1]));
        if (!strcmp(cmd,"where") || !strcmp(cmd,"having")) {
            ARGS(3,3,"statement predicate");
            if ((!strcmp(cmd,"where") && !contains("select update delete",k)) ||
                (!strcmp(cmd,"having") && strcmp(k,"select"))) return TpError(c,"VALIDATION","clause is not valid for this statement");
            Tcl_Obj *old=TpGet(c,d,cmd), *items=old?TpOwn(c,Tcl_DuplicateObj(old)):TpList(c);
            if (Tcl_ListObjAppendElement(c->interp,items,v[2])!=TCL_OK) return TCL_ERROR;
            TpPut(c,d,cmd,items);
        } else if (contains("order_by group_by returning",cmd)) {
            ARGS(3,INT_MAX,"statement expression ?expression ...?");
            if ((!strcmp(cmd,"returning") && !contains("insert update delete",k)) ||
                (strcmp(cmd,"returning") && strcmp(k,"select"))) return TpError(c,"VALIDATION","clause is not valid for this statement");
            Tcl_Obj *old=TpGet(c,d,cmd), *items=old?TpOwn(c,Tcl_DuplicateObj(old)):TpList(c);
            for (int i=2;i<objc;i++) if (Tcl_ListObjAppendElement(c->interp,items,TpColumn(c,v[i]))!=TCL_OK) return TCL_ERROR;
            TpPut(c,d,cmd,items);
        } else if (contains("limit offset distinct",cmd)) {
            ARGS(3,3,"statement value");
            if (strcmp(k,"select")) return TpError(c,"VALIDATION","clause requires a select statement");
            if (!strcmp(cmd,"distinct")) {
                int b; if(Tcl_GetBooleanFromObj(c->interp,v[2],&b)!=TCL_OK) return TCL_ERROR;
                TpPut(c,d,cmd,TpInt(c,b));
            } else {
                Tcl_WideInt n; if(TpWideInt(c,v[2],&n)!=TCL_OK) return TCL_ERROR;
                if(n<0) return TpError(c,"VALIDATION","limit and offset must be nonnegative integers");
                TpPut(c,d,cmd,TpInt(c,n));
            }
        } else if (!strcmp(cmd,"values")) {
            ARGS(3,4,"statement dictionary ?-expressions?");
            if (!contains("insert update",k)) return TpError(c,"VALIDATION","values requires insert or update");
            if(objc==4 && strcmp(OPT(3),"-expressions")) return TpError(c,"ARGS","expected -expressions");
            Tcl_Obj *old=TpGet(c,d,"values"), *values=old?TpOwn(c,Tcl_DuplicateObj(old)):TpDict(c);
            Tcl_DictSearch search; Tcl_Obj *key,*val; int done;
            if(Tcl_DictObjFirst(c->interp,v[2],&search,&key,&val,&done)!=TCL_OK) return TCL_ERROR;
            while(!done) {
                Tcl_Obj *node=val;
                if(objc==3) { node=TpNode(c,"value"); TpPut(c,node,"value",val); TpPut(c,node,"type",TpStr(c,"auto")); }
                Tcl_DictObjPut(NULL,values,key,node);
                Tcl_DictObjNext(&search,&key,&val,&done);
            }
            Tcl_DictObjDone(&search); TpPut(c,d,"values",values);
        } else if (!strcmp(cmd,"join")) {
            ARGS(4,6,"statement table predicate ?-type inner|left?");
            if(strcmp(k,"select")) return TpError(c,"VALIDATION","join requires select");
            if(objc!=4 && (objc!=6 || strcmp(OPT(4),"-type"))) return TpError(c,"ARGS","expected -type inner|left");
            const char *jt=objc==6?OPT(5):"inner";
            if(!contains("inner left",jt)) return TpError(c,"VALIDATION","join type must be inner or left");
            Tcl_Obj *join=TpDict(c), *old=TpGet(c,d,"joins"), *items=old?TpOwn(c,Tcl_DuplicateObj(old)):TpList(c);
            TpPut(c,join,"table",TpTable(c,v[2])); TpPut(c,join,"on",v[3]); TpPut(c,join,"type",TpStr(c,jt));
            if(Tcl_ListObjAppendElement(c->interp,items,join)!=TCL_OK) return TCL_ERROR;
            TpPut(c,d,"joins",items);
        } else if (!strcmp(cmd,"clear")) {
            ARGS(3,3,"statement clause");
            if(!contains("where having order_by group_by returning limit offset distinct values joins",OPT(2)))
                return TpError(c,"ARGS","unknown clause to clear");
            Tcl_DictObjRemove(NULL,d,v[2]);
        } else return TpError(c,"ARGS","unknown builder command");
    }
    *out=d;
    return TCL_OK;
#undef ARGS
#undef OPT
}

int TpBuilderCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    TpContext c={interp,Tcl_NewListObj(0,NULL)};
    Tcl_IncrRefCount(c.arena);
    Tcl_Obj *result=NULL;
    int code=build(&c,(const char *)data,objc,objv,&result);
    if(code==TCL_OK) Tcl_SetObjResult(interp,result);
    Tcl_DecrRefCount(c.arena);
    return code;
}
