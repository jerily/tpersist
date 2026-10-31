package require tcltest 2
set build [file normalize [lindex $argv 0]]
lappend auto_path $build
set argv [lrange $argv 1 end]
package require tpersist
if {[info exists ::env(TPERSIST_REQUIRE_SQLITE)] && $::env(TPERSIST_REQUIRE_SQLITE)} {
    package require tdbc::sqlite3
}
::tcltest::configure -testdir [file dirname [info script]] -singleproc 1 {*}$argv
set failed [::tcltest::runAllTests]
exit [expr {$failed ? 1 : 0}]
