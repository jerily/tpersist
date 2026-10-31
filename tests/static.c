#include <tcl.h>
#include "library.h"
#include <stdio.h>
int main(int argc,char **argv) {
    (void)argc;
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp=Tcl_CreateInterp();
    int code=Tcl_Init(interp);
    if(code==TCL_OK) code=Tpersist_Init(interp);
    if(code==TCL_OK) code=Tcl_Eval(interp,
        "namespace import ::tpersist::db_*; "
        /* Builder form: db_where [db_select users -columns {id}]
         *     [db_ge [db_col age] [db_value 18 -type integer]] */
        "set sql [dict get [db_compile [db_where [db_select users -expr {id}] -expr {age >= 18}]] sql]; "
        "if {$sql ne {SELECT \"id\" FROM \"users\" WHERE (\"age\" >= :p1)}} {error $sql}; "
        "if {[llength [info commands db_connect]] != 1} {error {missing embedded adapter}};");
    if(code!=TCL_OK) fprintf(stderr,"%s\n",Tcl_GetStringResult(interp));
    Tcl_DeleteInterp(interp); Tcl_Finalize();
    return code==TCL_OK?0:1;
}
