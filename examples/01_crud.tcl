# An in-memory database; no files or external services are required.
package require tpersist
namespace import ::tpersist::db_*

set db [db_connect -database :memory:]
try {
    set users [db_define_table users {
        id {type integer primary_key 1 auto_increment 1}
        name {type text not_null 1 unique 1}
        age {type integer not_null 1}
    }]
    db_create_table $db $users
    db_transaction $db {
        foreach {name age} {Alice 30 Bob 17 Carol 42} {
            db_execute $db [db_values [db_insert $users] [dict create name $name age $age]]
        }
    }

    # Reuse the same query with different parameter values.
    set adults [db_where [db_select $users -columns {id name age}] \
        [db_ge [db_col age] [db_param minimum -type integer]]]
    set adults [db_limit [db_order_by $adults [db_desc [db_col age]]] 10]
    puts "Adults: [dict get [db_execute $db $adults -params {minimum 18}] rows]"
    db_commit $db

    db_transaction $db {
        set birthday [db_values [db_update $users] \
            [dict create age [db_add [db_col age] [db_value 1 -type integer]]] -expressions]
        set birthday [db_where $birthday [db_eq [db_col name] [db_value Bob]]]
        puts "Updated: [dict get [db_execute $db [db_returning $birthday name age]] rows]"

        set remove [db_where [db_delete $users] [db_eq [db_col name] [db_value Alice]]]
        puts "Deleted: [dict get [db_execute $db $remove] rowcount]"
    }
    puts "Remaining: [dict get [db_execute $db [db_order_by [db_select $users] id]] rows]"
} finally { db_disconnect $db }
