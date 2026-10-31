/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include <math.h>

typedef struct {
    TpContext c;
    Tcl_DString sql;
    const char *dialect;
    Tcl_Obj *params, *types, *bindings, *nullNames, *required, *named, *used;
    unsigned int serial;
    int depth;
} Compiler;

#define ADD(s) Tcl_DStringAppend(&p->sql,(s),-1)
#define TRY(x) do { if ((x)!=TCL_OK) return TCL_ERROR; } while(0)

static Tcl_Obj *required(Compiler *p,Tcl_Obj *d,const char *key) {
    Tcl_Obj *o=TpGet(&p->c,d,key);
    if(!o) { Tcl_SetObjResult(p->c.interp,Tcl_ObjPrintf("missing dictionary field: %s",key)); Tcl_SetErrorCode(p->c.interp,"TPERSIST","VALIDATION",NULL); }
    return o;
}

static int keys(Compiler *p,Tcl_Obj *d,const char *allowed) {
    Tcl_DictSearch search; Tcl_Obj *key,*value; int done;
    if(Tcl_DictObjFirst(p->c.interp,d,&search,&key,&value,&done)!=TCL_OK)
        return TpError(&p->c,"VALIDATION","expected a dictionary");
    while(!done) {
        TpSize len; const char *s=Tcl_GetStringFromObj(key,&len);
        const char *at=allowed; int found=0;
        while(*at) {
            const char *end=strchr(at,' '); size_t n=end?(size_t)(end-at):strlen(at);
            if(n==(size_t)len && !memcmp(s,at,n)) { found=1; break; }
            at+=n; if(*at) at++;
        }
        if(!found) {
            Tcl_DictObjDone(&search);
            Tcl_SetObjResult(p->c.interp,Tcl_ObjPrintf("unknown or inapplicable dictionary field: %s",s));
            Tcl_SetErrorCode(p->c.interp,"TPERSIST","VALIDATION",NULL); return TCL_ERROR;
        }
        Tcl_DictObjNext(&search,&key,&value,&done);
    }
    Tcl_DictObjDone(&search); return TCL_OK;
}

static int identifier(Compiler *p,Tcl_Obj *o) {
    TpSize n; const char *s=Tcl_GetStringFromObj(o,&n);
    if(!n || memchr(s,0,(size_t)n) || strstr(s,"\xc0\x80")) return TpError(&p->c,"VALIDATION","identifiers must be nonempty and contain no NUL characters");
    char quote=!strcmp(p->dialect,"mysql")?'`':'"';
    Tcl_DStringAppend(&p->sql,&quote,1);
    for(TpSize i=0;i<n;i++) {
        Tcl_DStringAppend(&p->sql,s+i,1);
        if(s[i]==quote) Tcl_DStringAppend(&p->sql,&quote,1);
    }
    Tcl_DStringAppend(&p->sql,&quote,1); return TCL_OK;
}

static int table(Compiler *p,Tcl_Obj *d,int aliases) {
    TRY(keys(p,d,"node name schema alias"));
    Tcl_Obj *node=required(p,d,"node"), *name=required(p,d,"name");
    if(!node || !name) return TCL_ERROR;
    if(strcmp(Tcl_GetString(node),"table")) return TpError(&p->c,"VALIDATION","expected a table expression");
    Tcl_Obj *schema=TpGet(&p->c,d,"schema"), *alias=TpGet(&p->c,d,"alias");
    if(schema) { TRY(identifier(p,schema)); ADD("."); }
    TRY(identifier(p,name));
    if(alias) {
        if(!aliases) return TpError(&p->c,"UNSUPPORTED","table aliases on write statements are not supported");
        ADD(" AS "); TRY(identifier(p,alias));
    }
    return TCL_OK;
}

static int validType(Compiler *p,const char *type) {
    static const char *types[]={"auto","text","integer","bigint","real","double","boolean","binary","decimal","date","timestamp",NULL};
    for(int i=0;types[i];i++) if(!strcmp(types[i],type)) return TCL_OK;
    return TpError(&p->c,"TYPE","unknown parameter type");
}

static Tcl_Obj *convert(Compiler *p,Tcl_Obj *value,const char *type) {
    TpContext *c=&p->c;
    if(!strcmp(type,"integer") || !strcmp(type,"bigint")) {
        Tcl_WideInt n;
        if(TpWideInt(c,value,&n)!=TCL_OK) return NULL;
        return TpInt(c,n);
    }
    if(!strcmp(type,"boolean")) {
        int b; if(Tcl_GetBooleanFromObj(c->interp,value,&b)!=TCL_OK) return NULL;
        return TpOwn(c,Tcl_NewBooleanObj(b));
    }
    if(!strcmp(type,"real") || !strcmp(type,"double")) {
        double v; if(Tcl_GetDoubleFromObj(c->interp,value,&v)!=TCL_OK) return NULL;
        if(!isfinite(v)) { TpError(c,"TYPE","nonfinite floating-point values are not supported"); return NULL; }
        return TpOwn(c,Tcl_NewDoubleObj(v));
    }
    if(!strcmp(type,"binary")) {
        TpSize n; unsigned char *bytes=Tcl_GetByteArrayFromObj(value,&n);
        return TpOwn(c,Tcl_NewByteArrayObj(bytes,n));
    }
    if(!strcmp(type,"auto")) return value;
    TpSize n; const char *s=Tcl_GetStringFromObj(value,&n);
    return TpOwn(c,Tcl_NewStringObj(s,n));
}

static int bind(Compiler *p,Tcl_Obj *value,Tcl_Obj *name,const char *type) {
    TRY(validType(p,type));
    Tcl_Obj *slot=NULL;
    if(name) {
        TpSize len; const char *s=Tcl_GetStringFromObj(name,&len);
        if(!len || memchr(s,0,(size_t)len)) return TpError(&p->c,"VALIDATION","parameter name must not be empty or contain NUL");
        Tcl_DictObjGet(NULL,p->named,name,&slot);
        if(slot) {
            Tcl_Obj *oldType=NULL; Tcl_DictObjGet(NULL,p->types,slot,&oldType);
            if(strcmp(Tcl_GetString(oldType),type)) return TpError(&p->c,"TYPE","repeated named parameter has conflicting types");
            ADD(":"); ADD(Tcl_GetString(slot)); return TCL_OK;
        }
    }
    char buf[48]; snprintf(buf,sizeof(buf),"p%u",++p->serial);
    slot=TpStr(&p->c,buf);
    Tcl_DictObjPut(NULL,p->types,slot,TpStr(&p->c,type));
    if(name) {
        Tcl_Obj *nullFlag=NULL;
        Tcl_DictObjPut(NULL,p->named,name,slot);
        Tcl_DictObjPut(NULL,p->used,name,TpInt(&p->c,1));
        Tcl_DictObjGet(NULL,p->bindings,name,&value);
        Tcl_DictObjGet(NULL,p->nullNames,name,&nullFlag);
        if(nullFlag) value=NULL;
        else if(!value) Tcl_ListObjAppendElement(NULL,p->required,name);
    }
    if(value) {
        value=convert(p,value,type);
        if(!value) return TCL_ERROR;
        Tcl_DictObjPut(NULL,p->params,slot,value);
    }
    ADD(":"); ADD(buf); return TCL_OK;
}

enum { PROJECTION=1, ORDERING=2, STAR=4 };
static int expression(Compiler *p,Tcl_Obj *d,int flags);
static int exprBody(Compiler *p,Tcl_Obj *d,int flags) {
    Tcl_Obj *o=required(p,d,"node"); if(!o) return TCL_ERROR;
    const char *node=Tcl_GetString(o);
    if(!strcmp(node,"col")) {
        TRY(keys(p,d,"node name table"));
        Tcl_Obj *name=required(p,d,"name"), *qual=TpGet(&p->c,d,"table");
        if(!name) return TCL_ERROR;
        if(qual) { TRY(identifier(p,qual)); ADD("."); }
        return identifier(p,name);
    }
    if(!strcmp(node,"star")) {
        TRY(keys(p,d,"node table"));
        if(!(flags&STAR)) return TpError(&p->c,"VALIDATION","star is only valid in projections and count");
        o=TpGet(&p->c,d,"table"); if(o) { TRY(identifier(p,o)); ADD("."); }
        ADD("*"); return TCL_OK;
    }
    if(!strcmp(node,"null")) { TRY(keys(p,d,"node")); ADD("NULL"); return TCL_OK; }
    if(!strcmp(node,"value") || !strcmp(node,"param")) {
        int named=!strcmp(node,"param");
        TRY(keys(p,d,named?"node name type":"node value type"));
        Tcl_Obj *value=required(p,d,named?"name":"value"), *type=required(p,d,"type");
        if(!value || !type) return TCL_ERROR;
        return bind(p,named?NULL:value,named?value:NULL,Tcl_GetString(type));
    }
    if(!strcmp(node,"alias")) {
        TRY(keys(p,d,"node expr name"));
        if(!(flags&PROJECTION)) return TpError(&p->c,"VALIDATION","aliases are only valid in projections");
        Tcl_Obj *expr=required(p,d,"expr"), *name=required(p,d,"name");
        if(!expr || !name) return TCL_ERROR;
        TRY(expression(p,expr,0)); ADD(" AS "); return identifier(p,name);
    }
    static const char *binary[]={"eq","=","ne","<>","lt","<","le","<=","gt",">","ge",">=","like","LIKE","add","+","sub","-","mul","*","div","/",NULL};
    for(int i=0;binary[i];i+=2) if(!strcmp(node,binary[i])) {
        TRY(keys(p,d,"node left right"));
        Tcl_Obj *l=required(p,d,"left"), *r=required(p,d,"right");
        if(!l || !r) return TCL_ERROR;
        ADD("("); TRY(expression(p,l,0)); ADD(" "); ADD(binary[i+1]); ADD(" ");
        TRY(expression(p,r,0)); ADD(")"); return TCL_OK;
    }
    if(!strcmp(node,"and") || !strcmp(node,"or")) {
        TRY(keys(p,d,"node items"));
        o=required(p,d,"items"); if(!o) return TCL_ERROR;
        TpSize n; Tcl_Obj **v; TRY(Tcl_ListObjGetElements(p->c.interp,o,&n,&v));
        if(!n) return TpError(&p->c,"VALIDATION","and/or require at least one expression");
        ADD("(");
        for(TpSize i=0;i<n;i++) { if(i) ADD(!strcmp(node,"and")?" AND ":" OR "); TRY(expression(p,v[i],0)); }
        ADD(")"); return TCL_OK;
    }
    if(!strcmp(node,"in") || !strcmp(node,"not_in")) {
        TRY(keys(p,d,"node expr items"));
        Tcl_Obj *expr=required(p,d,"expr"); o=required(p,d,"items"); if(!o || !expr) return TCL_ERROR;
        TpSize n; Tcl_Obj **v; TRY(Tcl_ListObjGetElements(p->c.interp,o,&n,&v));
        /* Validate even an unused left expression, but do not leave unused binds. */
        if(!n) {
            Compiler check=*p; Tcl_DStringInit(&check.sql);
            check.params=TpDict(&p->c); check.types=TpDict(&p->c); check.named=TpDict(&p->c);
            check.required=TpList(&p->c); check.used=TpDict(&p->c);
            int code=expression(&check,expr,0); Tcl_DStringFree(&check.sql); TRY(code);
            ADD(!strcmp(node,"in")?"(1 = 0)":"(1 = 1)"); return TCL_OK;
        }
        ADD("("); TRY(expression(p,expr,0)); ADD(!strcmp(node,"in")?" IN (":" NOT IN (");
        for(TpSize i=0;i<n;i++) { if(i) ADD(", "); TRY(expression(p,v[i],0)); }
        ADD("))"); return TCL_OK;
    }
    const char *prefix=NULL,*suffix=NULL;
    int childFlags=0;
    if(!strcmp(node,"not")) { prefix="(NOT "; suffix=")"; }
    else if(!strcmp(node,"is_null")) { prefix="("; suffix=" IS NULL)"; }
    else if(!strcmp(node,"is_not_null")) { prefix="("; suffix=" IS NOT NULL)"; }
    else if(!strcmp(node,"asc") || !strcmp(node,"desc")) {
        if(!(flags&ORDERING)) return TpError(&p->c,"VALIDATION","asc/desc are only valid in order_by");
        prefix=""; suffix=!strcmp(node,"asc")?" ASC":" DESC";
    } else if(!strcmp(node,"count")) { prefix="COUNT("; suffix=")"; childFlags=STAR; }
    else if(!strcmp(node,"sum")) { prefix="SUM("; suffix=")"; }
    else if(!strcmp(node,"avg")) { prefix="AVG("; suffix=")"; }
    else if(!strcmp(node,"min")) { prefix="MIN("; suffix=")"; }
    else if(!strcmp(node,"max")) { prefix="MAX("; suffix=")"; }
    if(prefix) {
        TRY(keys(p,d,"node expr")); o=required(p,d,"expr"); if(!o) return TCL_ERROR;
        ADD(prefix); TRY(expression(p,o,childFlags)); ADD(suffix); return TCL_OK;
    }
    return TpError(&p->c,"VALIDATION","unknown expression node");
}

static int expression(Compiler *p,Tcl_Obj *d,int flags) {
    if(++p->depth>100) { --p->depth; return TpError(&p->c,"VALIDATION","expression nesting exceeds 100 levels"); }
    int code=exprBody(p,d,flags); --p->depth; return code;
}

static int clause(Compiler *p,Tcl_Obj *d,const char *key,const char *prefix,const char *separator,int flags,int mandatory) {
    Tcl_Obj *o=TpGet(&p->c,d,key);
    if(!o) return mandatory?TpError(&p->c,"VALIDATION","missing projection list"):TCL_OK;
    TpSize n; Tcl_Obj **v; TRY(Tcl_ListObjGetElements(p->c.interp,o,&n,&v));
    if(!n) return mandatory?TpError(&p->c,"VALIDATION","projection list cannot be empty"):TCL_OK;
    ADD(prefix);
    for(TpSize i=0;i<n;i++) { if(i) ADD(separator); TRY(expression(p,v[i],flags)); }
    return TCL_OK;
}

static int pagination(Compiler *p,Tcl_Obj *d) {
    Tcl_Obj *limit=TpGet(&p->c,d,"limit"), *offset=TpGet(&p->c,d,"offset");
    Tcl_Obj *values[]={limit,offset};
    for(int i=0;i<2;i++) if(values[i]) {
        Tcl_WideInt n; TRY(TpWideInt(&p->c,values[i],&n));
        if(n<0) return TpError(&p->c,"VALIDATION","limit and offset must be nonnegative");
    }
    if(limit) { ADD(" LIMIT "); TRY(bind(p,limit,NULL,"integer")); }
    else if(offset && !strcmp(p->dialect,"sqlite")) ADD(" LIMIT -1");
    else if(offset && !strcmp(p->dialect,"mysql")) ADD(" LIMIT 18446744073709551615");
    if(offset) { ADD(" OFFSET "); TRY(bind(p,offset,NULL,"integer")); }
    return TCL_OK;
}

static int statement(Compiler *p,Tcl_Obj *d) {
    Tcl_Obj *version=required(p,d,"version"), *kind=required(p,d,"kind"), *source=required(p,d,"table");
    if(!version || !kind || !source) return TCL_ERROR;
    int ver; TRY(Tcl_GetIntFromObj(p->c.interp,version,&ver));
    if(ver!=1) return TpError(&p->c,"VALIDATION","unsupported statement version");
    const char *k=Tcl_GetString(kind);
    if(!strcmp(k,"select")) {
        TRY(keys(p,d,"version kind table columns where joins group_by having order_by limit offset distinct"));
        ADD("SELECT "); Tcl_Obj *distinct=TpGet(&p->c,d,"distinct");
        if(distinct) { int b; TRY(Tcl_GetBooleanFromObj(p->c.interp,distinct,&b)); if(b) ADD("DISTINCT "); }
        TRY(clause(p,d,"columns","",", ",PROJECTION|STAR,1));
        ADD(" FROM "); TRY(table(p,source,1));
        Tcl_Obj *joins=TpGet(&p->c,d,"joins");
        if(joins) {
            TpSize n; Tcl_Obj **v; TRY(Tcl_ListObjGetElements(p->c.interp,joins,&n,&v));
            for(TpSize i=0;i<n;i++) {
                TRY(keys(p,v[i],"type table on"));
                Tcl_Obj *t=required(p,v[i],"type"), *src=required(p,v[i],"table"), *on=required(p,v[i],"on");
                if(!t || !src || !on) return TCL_ERROR;
                if(!strcmp(Tcl_GetString(t),"inner")) ADD(" INNER JOIN ");
                else if(!strcmp(Tcl_GetString(t),"left")) ADD(" LEFT JOIN ");
                else return TpError(&p->c,"VALIDATION","unsupported join type");
                TRY(table(p,src,1)); ADD(" ON "); TRY(expression(p,on,0));
            }
        }
        TRY(clause(p,d,"where"," WHERE "," AND ",0,0));
        TRY(clause(p,d,"group_by"," GROUP BY ",", ",0,0));
        TRY(clause(p,d,"having"," HAVING "," AND ",0,0));
        TRY(clause(p,d,"order_by"," ORDER BY ",", ",ORDERING,0));
        return pagination(p,d);
    }
    int insert=!strcmp(k,"insert"), update=!strcmp(k,"update"), del=!strcmp(k,"delete");
    if(!insert && !update && !del) return TpError(&p->c,"VALIDATION","unknown statement kind");
    TRY(keys(p,d,insert?"version kind table values returning":update?"version kind table values where returning":"version kind table where returning"));
    ADD(insert?"INSERT INTO ":update?"UPDATE ":"DELETE FROM "); TRY(table(p,source,0));
    if(!del) {
        Tcl_Obj *values=TpGet(&p->c,d,"values"); if(!values) values=TpDict(&p->c);
        TpSize n; TRY(Tcl_DictObjSize(p->c.interp,values,&n));
        if(!n) {
            if(update) return TpError(&p->c,"VALIDATION","update requires at least one assignment");
            ADD(!strcmp(p->dialect,"mysql")?" () VALUES ()":" DEFAULT VALUES");
        } else {
            Tcl_DictSearch search; Tcl_Obj *key,*val; int done,first=1,code=TCL_OK;
            ADD(insert?" (":" SET ");
            TRY(Tcl_DictObjFirst(p->c.interp,values,&search,&key,&val,&done));
            while(!done) {
                if(!first) ADD(", ");
                first=0;
                if((code=identifier(p,key))!=TCL_OK) break;
                if(update) { ADD(" = "); if((code=expression(p,val,0))!=TCL_OK) break; }
                Tcl_DictObjNext(&search,&key,&val,&done);
            }
            Tcl_DictObjDone(&search); TRY(code);
            if(insert) {
                ADD(") VALUES ("); first=1;
                TRY(Tcl_DictObjFirst(p->c.interp,values,&search,&key,&val,&done));
                while(!done) {
                    if(!first) ADD(", ");
                    first=0;
                    if((code=expression(p,val,0))!=TCL_OK) break;
                    Tcl_DictObjNext(&search,&key,&val,&done);
                }
                Tcl_DictObjDone(&search); TRY(code); ADD(")");
            }
        }
    }
    if(!insert) TRY(clause(p,d,"where"," WHERE "," AND ",0,0));
    Tcl_Obj *ret=TpGet(&p->c,d,"returning");
    if(ret) {
        TpSize n; TRY(Tcl_ListObjLength(p->c.interp,ret,&n));
        if(n && !strcmp(p->dialect,"mysql")) return TpError(&p->c,"UNSUPPORTED","RETURNING is not supported by the mysql dialect");
    }
    return clause(p,d,"returning"," RETURNING ",", ",PROJECTION|STAR,0);
}

int TpCompileCmd(ClientData unused,Tcl_Interp *interp,int objc,Tcl_Obj *const objv[]) {
    (void)unused;
    if(objc<2 || objc%2!=0) { Tcl_WrongNumArgs(interp,1,objv,"statement ?-dialect sqlite|postgresql|mysql? ?-params dict? ?-nulls names?"); return TCL_ERROR; }
    Compiler p={0}; p.c.interp=interp; p.c.arena=Tcl_NewListObj(0,NULL); Tcl_IncrRefCount(p.c.arena);
    Tcl_DStringInit(&p.sql); p.dialect="sqlite";
    p.params=TpDict(&p.c); p.types=TpDict(&p.c); p.bindings=TpDict(&p.c); p.nullNames=TpDict(&p.c);
    p.required=TpList(&p.c); p.named=TpDict(&p.c); p.used=TpDict(&p.c);
    int code=TCL_ERROR;
    for(int i=2;i<objc;i+=2) {
        const char *opt=Tcl_GetString(objv[i]);
        if(!strcmp(opt,"-dialect")) p.dialect=Tcl_GetString(objv[i+1]);
        else if(!strcmp(opt,"-params")) {
            TpSize n; if(Tcl_DictObjSize(interp,objv[i+1],&n)!=TCL_OK) goto done;
            p.bindings=objv[i+1];
        } else if(!strcmp(opt,"-nulls")) {
            TpSize n; Tcl_Obj **v;
            if(Tcl_ListObjGetElements(interp,objv[i+1],&n,&v)!=TCL_OK) goto done;
            for(TpSize j=0;j<n;j++) Tcl_DictObjPut(NULL,p.nullNames,v[j],TpInt(&p.c,1));
        } else { TpError(&p.c,"ARGS","unknown compile option"); goto done; }
    }
    if(strcmp(p.dialect,"sqlite") && strcmp(p.dialect,"postgresql") && strcmp(p.dialect,"mysql")) {
        TpError(&p.c,"DIALECT","dialect must be sqlite, postgresql, or mysql"); goto done;
    }
    if(statement(&p,objv[1])!=TCL_OK) goto done;
    /* Catch misspelled bindings; explicit NULL must not also have a value. */
    Tcl_Obj *sets[]={p.bindings,p.nullNames};
    for(int i=0;i<2;i++) {
        Tcl_DictSearch search; Tcl_Obj *key,*val,*found; int end;
        Tcl_DictObjFirst(NULL,sets[i],&search,&key,&val,&end);
        while(!end) {
            Tcl_DictObjGet(NULL,p.used,key,&found);
            if(!found) { Tcl_DictObjDone(&search); TpError(&p.c,"PARAMETER","provided parameter is not used by the statement"); goto done; }
            if(i==1) {
                Tcl_DictObjGet(NULL,p.bindings,key,&found);
                if(found) { Tcl_DictObjDone(&search); TpError(&p.c,"PARAMETER","parameter cannot have both a value and NULL"); goto done; }
            }
            Tcl_DictObjNext(&search,&key,&val,&end);
        }
        Tcl_DictObjDone(&search);
    }
    Tcl_Obj *result=TpDict(&p.c);
    TpPut(&p.c,result,"sql",TpOwn(&p.c,Tcl_NewStringObj(Tcl_DStringValue(&p.sql),Tcl_DStringLength(&p.sql))));
    TpPut(&p.c,result,"params",p.params); TpPut(&p.c,result,"types",p.types);
    TpPut(&p.c,result,"required",p.required); TpPut(&p.c,result,"dialect",TpStr(&p.c,p.dialect));
    Tcl_SetObjResult(interp,result); code=TCL_OK;
done:
    Tcl_DStringFree(&p.sql); Tcl_DecrRefCount(p.c.arena); return code;
}
