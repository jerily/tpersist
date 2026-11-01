package require tpersist::oo
namespace import ::tpersist::db_*

set database [::tpersist::oo::Database new -database :memory:]
try {
    $database create_table [db_define_table customers {
        id {type integer primary_key 1}
        name {type text unique 1 not_null 1}
    }]
    set orders [db_define_table orders {
        id {type integer primary_key 1}
        customer_id {type integer not_null 1}
        total_cents {type integer not_null 1}
    } -foreign_keys [list [dict create columns customer_id table customers \
        referenced_columns id on_delete cascade]]]
    $database create_table $orders
    $database create_index orders_customer orders customer_id
    set insertCustomer [$database insert customers]
    set insertOrder [$database insert orders]
    $database transaction {
        foreach {id name} {1 Alice 2 Bob 3 Carol} {
            $insertCustomer values [dict create id $id name $name]
            $insertCustomer execute
        }
        foreach {id customer amount} {1 1 1200 2 1 3400 3 2 800} {
            $insertOrder values [dict create id $id customer_id $customer total_cents $amount]
            $insertOrder execute
        }
    }

    # set query [$database select [db_table customers -as c] -columns [list \
    #     [db_col name -table c] \
    #     [db_alias [db_count [db_col id -table o]] order_count] \
    #     [db_alias [db_sum [db_col total_cents -table o]] spent_cents]]]
    set query [$database select [db_table customers -as c] -expr {
        c.name, COUNT(o.id) AS order_count, SUM(o.total_cents) AS spent_cents
    }]
    # $query join [db_table orders -as o] \
    #     [db_eq [db_col id -table c] [db_col customer_id -table o]] -type left
    $query join [db_table orders -as o] -expr {c.id = o.customer_id} -type left
    # $query group_by [db_col name -table c]
    $query group_by -expr {c.name}
    # $query order_by [db_col name -table c]
    $query order_by -expr {c.name}
    $query foreach_row row {
        # Carol has no orders: the SQL NULL sum has no dictionary key.
        set amount [expr {[dict exists $row spent_cents] ? [dict get $row spent_cents] : 0}]
        puts "[dict get $row name]: [dict get $row order_count] orders, $amount cents"
    }
    # Fork before adding HAVING to keep the original query unchanged.
    set frequent [$query fork]
    # $frequent having [db_ge [db_count [db_col id -table o]] [db_value 2 -type integer]]
    $frequent having -expr {COUNT(o.id) >= 2}
    puts "Frequent customers: [$frequent all]"
} finally {
    # Also destroys its queries and disconnects the TDBC connection.
    $database destroy
}
