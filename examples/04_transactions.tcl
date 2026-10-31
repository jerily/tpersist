package require tpersist
namespace import ::tpersist::db_*

set db [db_connect -database :memory:]
try {
    db_create_table $db [db_define_table accounts {name {type text primary_key 1} balance {type integer not_null 1}}]
    db_transaction $db {
        db_execute $db [db_values [db_insert accounts] {name Alice balance 100}]
        db_execute $db [db_values [db_insert accounts] {name Bob balance 20}]
    }
    db_transaction $db {
        set alice [db_where [db_update accounts] [db_eq [db_col name] [db_value Alice]]]
        set bob [db_where [db_update accounts] [db_eq [db_col name] [db_value Bob]]]
        db_execute $db [db_values $alice {balance 90}]
        db_execute $db [db_values $bob {balance 30}]

        # This nested scope has its own savepoint. Its failure does not undo
        # the successful transfer in the surrounding transaction.
        if {[catch {db_transaction $db {
            db_execute $db [db_values $alice {balance 0}]
            error "Rejected optional adjustment"
        }} message]} { puts $message }
    }
    puts "After transfer: [dict get [db_execute $db [db_order_by [db_select accounts] name]] rows]"
    db_commit $db

    db_begin $db
    db_savepoint $db experiment
    db_execute $db [db_delete accounts]
    db_rollback_to $db experiment
    db_release $db experiment
    db_commit $db
    puts "After undo: [dict get [db_execute $db [db_order_by [db_select accounts] name]] rows]"
} finally { db_disconnect $db }
