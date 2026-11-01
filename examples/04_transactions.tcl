package require tpersist::oo
namespace import ::tpersist::db_*

set database [::tpersist::oo::Database new -database :memory:]
try {
    $database create_table [db_define_table accounts {name {type text primary_key 1} balance {type integer not_null 1}}]
    set insert [$database insert accounts]
    $database transaction {
        $insert values {name Alice balance 100}
        $insert execute
        $insert values {name Bob balance 20}
        $insert execute
    }
    $database transaction {
        set alice [$database update accounts]
        # $alice where [db_eq [db_col name] [db_value Alice]]
        $alice where -expr {name = 'Alice'}
        set bob [$database update accounts]
        # $bob where [db_eq [db_col name] [db_value Bob]]
        $bob where -expr {name = 'Bob'}
        $alice values {balance 90}
        $alice execute
        $bob values {balance 30}
        $bob execute

        # This nested scope has its own savepoint. Its failure does not undo
        # the successful transfer in the surrounding transaction.
        if {[catch {$database transaction {
            # Rollback affects database rows, not mutable query objects.
            set adjustment [$alice fork]
            $adjustment values {balance 0}
            $adjustment execute
            error "Rejected optional adjustment"
        }} message]} { puts $message }
    }
    set accounts [$database select accounts]
    # $accounts order_by name
    $accounts order_by -expr {name}
    puts "After transfer: [$accounts all]"
    $database commit

    # Explicit savepoints use the procedural API with a borrowed connection.
    set connection [$database connection]
    $database begin
    db_savepoint $connection experiment
    set remove [$database delete accounts]
    $remove execute
    db_rollback_to $connection experiment
    db_release $connection experiment
    $database commit
    puts "After undo: [$accounts all]"
} finally {
    # Also destroys its queries and disconnects the TDBC connection.
    $database destroy
}
