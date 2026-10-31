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
        "set sql [dict get [db_compile [db_select users -columns {id}]] sql]; "
        "if {$sql ne {SELECT \"id\" FROM \"users\"}} {error $sql}; "
        "if {[llength [info commands db_connect]] != 1} {error {missing embedded adapter}};");
    if(code!=TCL_OK) fprintf(stderr,"%s\n",Tcl_GetStringResult(interp));
    Tcl_DeleteInterp(interp); Tcl_Finalize();
    return code==TCL_OK?0:1;
}
