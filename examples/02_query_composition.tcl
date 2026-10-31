# Offline compilation works without TDBC or a running database.
package require tpersist
namespace import ::tpersist::db_*

set base [db_select [db_table products -as p] -columns {id name price}]
set available [db_where $base [db_and \
    [db_eq [db_col active] [db_value 1 -type boolean]] \
    [db_is_null [db_col deleted_at]]]]
set search [db_where $available [db_or \
    [db_like [db_col name] [db_param pattern -type text]] \
    [db_in [db_col category] [list [db_value books] [db_value music]]]]]
set search [db_order_by $search [db_asc [db_col price]] [db_asc [db_col id]]]
set page [db_offset [db_limit $search 20] 40]

foreach dialect {sqlite postgresql mysql} {
    set compiled [db_compile $page -dialect $dialect -params {pattern {%Tcl%}}]
    puts "$dialect: [dict get $compiled sql]"
    puts "  bindings: [dict get $compiled params]"
}
puts "Base remains: [dict get [db_compile $base] sql]"
puts "Unpaged search: [dict get [db_compile $search] sql]"
puts "Required parameters: [dict get [db_compile $search] required]"
