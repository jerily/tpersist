/* SPDX-License-Identifier: MIT */
#include "internal.h"

/* A deliberately small SQL-style expression grammar. No SQL fragments or Tcl
 * scripts are evaluated: every accepted token becomes an existing AST node.
 * Token offsets are bytes internally; diagnostics use Tcl character positions. */
enum { END=0, WORD=256, QIDENT, STRING, NUMBER, PARAM, NE, LE, GE };
typedef struct {
    TpContext *c;
    const char *source;
    TpSize length, cursor, start;
    int token, failed, depth;
    Tcl_Obj *text;
} Parser;

static int failAt(Parser *p,TpSize offset,const char *message) {
    if(!p->failed) {
        Tcl_WideInt position=(Tcl_WideInt)Tcl_NumUtfChars(p->source,offset)+1;
        Tcl_SetObjResult(p->c->interp,Tcl_ObjPrintf("expression parse error at character %lld: %s",(long long)position,message));
        Tcl_Obj *code=TpList(p->c);
        Tcl_ListObjAppendElement(NULL,code,TpStr(p->c,"TPERSIST"));
        Tcl_ListObjAppendElement(NULL,code,TpStr(p->c,"PARSE"));
        Tcl_ListObjAppendElement(NULL,code,TpInt(p->c,position));
        Tcl_SetObjErrorCode(p->c->interp,code);
        p->failed=1;
    }
    return 0;
}

static int letter(unsigned char ch) {
    return (ch>='a' && ch<='z') || (ch>='A' && ch<='Z') || ch=='_';
}
static int digit(unsigned char ch) { return ch>='0' && ch<='9'; }
static int space(unsigned char ch) {
    return ch==' ' || ch=='\t' || ch=='\r' || ch=='\n' || ch=='\f' || ch=='\v';
}
static int equals(Tcl_Obj *text,const char *word) {
    TpSize n; const char *s=Tcl_GetStringFromObj(text,&n);
    if((size_t)n!=strlen(word)) return 0;
    for(TpSize i=0;i<n;i++) {
        unsigned char ch=(unsigned char)s[i];
        if(ch>='a' && ch<='z') ch=(unsigned char)(ch-'a'+'A');
        if(ch!=(unsigned char)word[i]) return 0;
    }
    return 1;
}
static int word(Parser *p,const char *s) { return p->token==WORD && equals(p->text,s); }

static int next(Parser *p) {
    if(p->failed) return 0;
    const char *s=p->source;
    TpSize n=p->length, i=p->cursor;
    while(i<n && space((unsigned char)s[i])) i++;
    p->start=i; p->text=NULL;
    if(i==n) { p->cursor=i; p->token=END; return 1; }
    unsigned char ch=(unsigned char)s[i++];
    if(ch=='\'' || ch=='"' || ch=='`') {
        Tcl_DString decoded; Tcl_DStringInit(&decoded);
        int closed=0;
        while(i<n) {
            if((unsigned char)s[i]==ch) {
                i++;
                if(i<n && (unsigned char)s[i]==ch) {
                    Tcl_DStringAppend(&decoded,s+i,1); i++;
                } else { closed=1; break; }
            } else { Tcl_DStringAppend(&decoded,s+i,1); i++; }
        }
        if(!closed) {
            Tcl_DStringFree(&decoded);
            return failAt(p,p->start,"unterminated quoted string or identifier");
        }
        if(ch!='\'' && (!Tcl_DStringLength(&decoded) ||
            memchr(Tcl_DStringValue(&decoded),0,(size_t)Tcl_DStringLength(&decoded)) ||
            strstr(Tcl_DStringValue(&decoded),"\xc0\x80"))) {
            Tcl_DStringFree(&decoded);
            return failAt(p,p->start,"identifier must be nonempty and contain no NUL");
        }
        p->text=TpOwn(p->c,Tcl_NewStringObj(Tcl_DStringValue(&decoded),Tcl_DStringLength(&decoded)));
        Tcl_DStringFree(&decoded);
        p->token=ch=='\''?STRING:QIDENT;
    } else if(letter(ch) || ch==':') {
        TpSize begin=p->start;
        if(ch==':') {
            begin=i;
            if(i==n || !letter((unsigned char)s[i])) return failAt(p,p->start,"expected a parameter name after ':'");
            i++;
        }
        while(i<n && (letter((unsigned char)s[i]) || digit((unsigned char)s[i]))) i++;
        p->text=TpOwn(p->c,Tcl_NewStringObj(s+begin,i-begin));
        p->token=ch==':'?PARAM:WORD;
    } else if(digit(ch) || (ch=='.' && i<n && digit((unsigned char)s[i]))) {
        while(i<n && digit((unsigned char)s[i])) i++;
        if(ch!='.' && i<n && s[i]=='.') {
            i++;
            while(i<n && digit((unsigned char)s[i])) i++;
        }
        if(i<n && (s[i]=='e' || s[i]=='E')) {
            i++;
            if(i<n && (s[i]=='+' || s[i]=='-')) i++;
            if(i==n || !digit((unsigned char)s[i])) return failAt(p,i,"expected exponent digits");
            while(i<n && digit((unsigned char)s[i])) i++;
        }
        if(i<n && (letter((unsigned char)s[i]) || (unsigned char)s[i]>=0x80))
            return failAt(p,i,"expected a separator after the number");
        p->text=TpOwn(p->c,Tcl_NewStringObj(s+p->start,i-p->start));
        p->token=NUMBER;
    } else {
        p->token=ch;
        if(i<n && ((ch=='-' && s[i]=='-') || (ch=='/' && s[i]=='*')))
            return failAt(p,p->start,"SQL comments are not supported in expressions");
        if(ch=='<' && i<n && s[i]=='=') { p->token=LE; i++; }
        else if(ch=='>' && i<n && s[i]=='=') { p->token=GE; i++; }
        else if(ch=='<' && i<n && s[i]=='>') { p->token=NE; i++; }
        else if(ch=='!' && i<n && s[i]=='=') { p->token=NE; i++; }
        else if(!strchr("()+-*/=<>.,",ch) || ch==0)
            return failAt(p,p->start,"unexpected character (use :name for parameters and quotes for identifiers)");
    }
    p->cursor=i;
    return 1;
}

static int reserved(Parser *p) {
    static const char *words[]={"AND","OR","NOT","IS","NULL","TRUE","FALSE","LIKE","IN",
        "AS","ASC","DESC","SELECT","FROM","WHERE","GROUP","BY","HAVING","ORDER",
        "LIMIT","OFFSET","JOIN","ON","CASE","WHEN","THEN","ELSE","END","DISTINCT",
        "BETWEEN","EXISTS","CAST","OVER","UNION","EXCEPT","INTERSECT","INSERT","UPDATE",
        "DELETE","WITH","RETURNING","ESCAPE","COLLATE","NULLS","FIRST","LAST","ILIKE",
        "ANY","ALL","SOME",NULL};
    for(int i=0;words[i];i++) if(word(p,words[i])) return 1;
    return 0;
}

static Tcl_Obj *unary(Parser *p,const char *kind,Tcl_Obj *child) {
    Tcl_Obj *node=TpNode(p->c,kind);
    TpPut(p->c,node,"expr",child);
    return node;
}
static Tcl_Obj *binary(Parser *p,const char *kind,Tcl_Obj *left,Tcl_Obj *right) {
    Tcl_Obj *node=TpNode(p->c,kind);
    TpPut(p->c,node,"left",left); TpPut(p->c,node,"right",right);
    return node;
}
static Tcl_Obj *literal(Parser *p,Tcl_Obj *value,const char *type) {
    Tcl_Obj *node=TpNode(p->c,"value");
    TpPut(p->c,node,"value",value); TpPut(p->c,node,"type",TpStr(p->c,type));
    return node;
}

static int enter(Parser *p) {
    if(p->depth>=100) return failAt(p,p->start,"expression nesting exceeds 100 levels");
    p->depth++; return 1;
}
static Tcl_Obj *parseOr(Parser *p);
static Tcl_Obj *parseUnary(Parser *p);

static Tcl_Obj *number(Parser *p,int negative) {
    const char *s=Tcl_GetString(p->text);
    const char *type=strpbrk(s,".eE")?"decimal":"integer";
    if(!strcmp(type,"integer")) while(s[0]=='0' && s[1]) s++;
    if(!strcmp(type,"integer") && (strlen(s)>19 ||
        (strlen(s)==19 && strcmp(s,negative?"9223372036854775808":"9223372036854775807")>0))) {
        failAt(p,p->start,"integer literal is outside the signed 64-bit range");
        return NULL;
    }
    Tcl_Obj *value=TpOwn(p->c,Tcl_ObjPrintf("%s%s",negative?"-":"",s));
    if(!strcmp(type,"integer")) {
        Tcl_WideInt v;
        if(TpWideInt(p->c,value,&v)!=TCL_OK) {
            failAt(p,p->start,"integer literal is outside the signed 64-bit range");
            return NULL;
        }
        value=TpInt(p->c,v);
    }
    Tcl_Obj *node=literal(p,value,type);
    return next(p)?node:NULL;
}

static Tcl_Obj *identifierToken(Parser *p) {
    if((p->token!=WORD && p->token!=QIDENT) || reserved(p)) {
        failAt(p,p->start,"expected an identifier; quote reserved words"); return NULL;
    }
    Tcl_Obj *name=p->text;
    return next(p)?name:NULL;
}

static Tcl_Obj *primary(Parser *p) {
    if(p->token==NUMBER) return number(p,0);
    if(p->token==STRING) {
        Tcl_Obj *node=literal(p,p->text,"text");
        return next(p)?node:NULL;
    }
    if(p->token==PARAM) {
        Tcl_Obj *node=TpNode(p->c,"param");
        TpPut(p->c,node,"name",p->text); TpPut(p->c,node,"type",TpStr(p->c,"auto"));
        return next(p)?node:NULL;
    }
    if(word(p,"NULL")) {
        Tcl_Obj *node=TpNode(p->c,"null"); return next(p)?node:NULL;
    }
    if(word(p,"TRUE") || word(p,"FALSE")) {
        Tcl_Obj *node=literal(p,TpInt(p->c,word(p,"TRUE")),"boolean");
        return next(p)?node:NULL;
    }
    if(p->token=='*') {
        Tcl_Obj *node=TpNode(p->c,"star"); return next(p)?node:NULL;
    }
    if(p->token=='(') {
        if(!next(p) || !enter(p)) return NULL;
        Tcl_Obj *node=parseOr(p); p->depth--;
        if(!node) return NULL;
        if(p->token!=')') { failAt(p,p->start,"expected ')'"); return NULL; }
        return next(p)?node:NULL;
    }
    if(p->token==WORD || p->token==QIDENT) {
        TpSize start=p->start;
        int quoted=p->token==QIDENT;
        Tcl_Obj *name=identifierToken(p);
        if(!name) return NULL;
        if(p->token=='(') {
            const char *kind=NULL;
            if(!quoted) {
                if(equals(name,"COUNT")) kind="count";
                else if(equals(name,"SUM")) kind="sum";
                else if(equals(name,"AVG")) kind="avg";
                else if(equals(name,"MIN")) kind="min";
                else if(equals(name,"MAX")) kind="max";
            }
            if(!kind) { failAt(p,start,"only COUNT, SUM, AVG, MIN, and MAX functions are supported"); return NULL; }
            if(!next(p) || !enter(p)) return NULL;
            Tcl_Obj *arg=parseOr(p); p->depth--;
            if(!arg) return NULL;
            if(p->token!=')') { failAt(p,p->start,"expected ')' after one function argument"); return NULL; }
            Tcl_Obj *node=unary(p,kind,arg);
            return next(p)?node:NULL;
        }
        Tcl_Obj *qualifier=NULL;
        if(p->token=='.') {
            qualifier=name;
            if(!next(p)) return NULL;
            if(p->token=='*') {
                Tcl_Obj *node=TpNode(p->c,"star"); TpPut(p->c,node,"table",qualifier);
                return next(p)?node:NULL;
            }
            name=identifierToken(p); if(!name) return NULL;
        }
        Tcl_Obj *node=TpNode(p->c,"col"); TpPut(p->c,node,"name",name);
        if(qualifier) TpPut(p->c,node,"table",qualifier);
        return node;
    }
    failAt(p,p->start,"expected an expression"); return NULL;
}

static Tcl_Obj *parseUnary(Parser *p) {
    if(p->token!='+' && p->token!='-') return primary(p);
    int negative=p->token=='-';
    if(!next(p)) return NULL;
    if(p->token==NUMBER) return number(p,negative);
    if(!enter(p)) return NULL;
    Tcl_Obj *node=parseUnary(p); p->depth--;
    if(!node) return NULL;
    return negative?binary(p,"sub",literal(p,TpInt(p->c,0),"integer"),node):node;
}

static Tcl_Obj *multiply(Parser *p) {
    Tcl_Obj *left=parseUnary(p); if(!left) return NULL;
    while(p->token=='*' || p->token=='/') {
        const char *kind=p->token=='*'?"mul":"div";
        if(!next(p)) return NULL;
        Tcl_Obj *right=parseUnary(p); if(!right) return NULL;
        left=binary(p,kind,left,right);
    }
    return left;
}
static Tcl_Obj *add(Parser *p) {
    Tcl_Obj *left=multiply(p); if(!left) return NULL;
    while(p->token=='+' || p->token=='-') {
        const char *kind=p->token=='+'?"add":"sub";
        if(!next(p)) return NULL;
        Tcl_Obj *right=multiply(p); if(!right) return NULL;
        left=binary(p,kind,left,right);
    }
    return left;
}

static Tcl_Obj *compare(Parser *p) {
    Tcl_Obj *left=add(p); if(!left) return NULL;
    const char *kind=NULL;
    switch(p->token) {
        case '=': kind="eq"; break; case NE: kind="ne"; break;
        case '<': kind="lt"; break; case LE: kind="le"; break;
        case '>': kind="gt"; break; case GE: kind="ge"; break;
    }
    if(kind) {
        if(!next(p)) return NULL;
        Tcl_Obj *right=add(p); return right?binary(p,kind,left,right):NULL;
    }
    if(word(p,"IS")) {
        if(!next(p)) return NULL;
        int negate=word(p,"NOT");
        if(negate && !next(p)) return NULL;
        if(!word(p,"NULL")) { failAt(p,p->start,"expected NULL after IS or IS NOT"); return NULL; }
        Tcl_Obj *node=unary(p,negate?"is_not_null":"is_null",left);
        return next(p)?node:NULL;
    }
    int negate=word(p,"NOT");
    if(negate && !next(p)) return NULL;
    if(word(p,"LIKE")) {
        if(!next(p)) return NULL;
        Tcl_Obj *right=add(p); if(!right) return NULL;
        Tcl_Obj *node=binary(p,"like",left,right);
        return negate?unary(p,"not",node):node;
    }
    if(word(p,"IN")) {
        if(!next(p)) return NULL;
        if(p->token!='(') { failAt(p,p->start,"expected '(' after IN"); return NULL; }
        if(!next(p)) return NULL;
        Tcl_Obj *items=TpList(p->c);
        if(p->token!=')') {
            for(;;) {
                if(!enter(p)) return NULL;
                Tcl_Obj *item=parseOr(p); p->depth--;
                if(!item) return NULL;
                Tcl_ListObjAppendElement(NULL,items,item);
                if(p->token!=',') break;
                if(!next(p)) return NULL;
            }
        }
        if(p->token!=')') { failAt(p,p->start,"expected ')' after IN values"); return NULL; }
        Tcl_Obj *node=unary(p,negate?"not_in":"in",left); TpPut(p->c,node,"items",items);
        return next(p)?node:NULL;
    }
    if(negate) { failAt(p,p->start,"expected IN or LIKE after NOT"); return NULL; }
    return left;
}

static Tcl_Obj *parseNot(Parser *p) {
    if(!word(p,"NOT")) return compare(p);
    if(!next(p) || !enter(p)) return NULL;
    Tcl_Obj *node=parseNot(p); p->depth--;
    return node?unary(p,"not",node):NULL;
}
static Tcl_Obj *parseAnd(Parser *p) {
    Tcl_Obj *first=parseNot(p); if(!first) return NULL;
    if(!word(p,"AND")) return first;
    Tcl_Obj *items=TpList(p->c); Tcl_ListObjAppendElement(NULL,items,first);
    while(word(p,"AND")) {
        if(!next(p)) return NULL;
        Tcl_Obj *node=parseNot(p); if(!node) return NULL;
        Tcl_ListObjAppendElement(NULL,items,node);
    }
    Tcl_Obj *node=TpNode(p->c,"and"); TpPut(p->c,node,"items",items); return node;
}
static Tcl_Obj *parseOr(Parser *p) {
    Tcl_Obj *first=parseAnd(p); if(!first) return NULL;
    if(!word(p,"OR")) return first;
    Tcl_Obj *items=TpList(p->c); Tcl_ListObjAppendElement(NULL,items,first);
    while(word(p,"OR")) {
        if(!next(p)) return NULL;
        Tcl_Obj *node=parseAnd(p); if(!node) return NULL;
        Tcl_ListObjAppendElement(NULL,items,node);
    }
    Tcl_Obj *node=TpNode(p->c,"or"); TpPut(p->c,node,"items",items); return node;
}

int TpParseExpression(TpContext *c,Tcl_Obj *source,TpParseMode mode,Tcl_Obj **result) {
    Parser p={0}; p.c=c; p.source=Tcl_GetStringFromObj(source,&p.length);
    if(!next(&p)) return TCL_ERROR;
    int list=mode==TP_PARSE_COLUMNS || mode==TP_PARSE_ORDER || mode==TP_PARSE_GROUP;
    int flags=mode==TP_PARSE_COLUMNS?TP_PROJECTION|TP_STAR:
        mode==TP_PARSE_ORDER?TP_ORDERING:
        mode==TP_PARSE_SINGLE?TP_PROJECTION|TP_ORDERING|TP_STAR:0;
    Tcl_Obj *items=TpList(c), *node=NULL;
    for(;;) {
        TpSize start=p.start;
        node=parseOr(&p); if(!node) return TCL_ERROR;
        if(word(&p,"AS") && (flags&TP_PROJECTION)) {
            if(!next(&p)) return TCL_ERROR;
            Tcl_Obj *alias=identifierToken(&p); if(!alias) return TCL_ERROR;
            node=unary(&p,"alias",node); TpPut(c,node,"name",alias);
        } else if((word(&p,"ASC") || word(&p,"DESC")) && (flags&TP_ORDERING)) {
            node=unary(&p,word(&p,"ASC")?"asc":"desc",node);
            if(!next(&p)) return TCL_ERROR;
        }
        if(TpCheckExpression(c,node,flags)!=TCL_OK) {
            Tcl_Obj *message=TpOwn(c,Tcl_DuplicateObj(Tcl_GetObjResult(c->interp)));
            failAt(&p,start,Tcl_GetString(message)); return TCL_ERROR;
        }
        Tcl_ListObjAppendElement(NULL,items,node);
        if(p.token==END) break;
        if(!list || p.token!=',') {
            failAt(&p,p.start,list?"expected ',' or end of expression list":"expected end of expression");
            return TCL_ERROR;
        }
        if(!next(&p)) return TCL_ERROR;
    }
    *result=list?items:node;
    return TCL_OK;
}

int TpExprCmd(ClientData unused,Tcl_Interp *interp,int objc,Tcl_Obj *const objv[]) {
    (void)unused;
    if(objc!=2) { Tcl_WrongNumArgs(interp,1,objv,"expression"); return TCL_ERROR; }
    TpContext c={interp,Tcl_NewListObj(0,NULL)}; Tcl_IncrRefCount(c.arena);
    Tcl_Obj *node=NULL;
    int code=TpParseExpression(&c,objv[1],TP_PARSE_SINGLE,&node);
    if(code==TCL_OK) Tcl_SetObjResult(interp,node);
    Tcl_DecrRefCount(c.arena); return code;
}
