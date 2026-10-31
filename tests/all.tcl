package require tcltest 2
set build [file normalize [lindex $argv 0]]
set auto_path [linsert $auto_path 0 $build]
# Register this build explicitly so an installed package of the same version
# cannot supply an older core or optional OO script during a test run.
apply {{dir} {source [file join $dir pkgIndex.tcl]}} $build
set argv [lrange $argv 1 end]
package require tpersist
if {[info exists ::env(TPERSIST_REQUIRE_SQLITE)] && $::env(TPERSIST_REQUIRE_SQLITE)} {
    package require tdbc::sqlite3
}
::tcltest::configure -testdir [file dirname [info script]] -singleproc 1 {*}$argv
set failed [::tcltest::runAllTests]
exit [expr {$failed ? 1 : 0}]
