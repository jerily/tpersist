# A separate interpreter/connection for counter contention tests.
lassign $argv paths dialect options table start
set auto_path $paths
package require tpersist
namespace import ::tpersist::db_*
set db [db_connect -dialect $dialect -autobegin 0 {*}$options]
after [expr {max(0, $start - [clock milliseconds])}]
set values {}
for {set i 0} {$i < 20} {incr i} {
    lappend values [db_increment $db $table {tenant shared id first} hits -initial [dict create expires 100 label worker-[pid]]]
}
puts $values
db_disconnect $db
