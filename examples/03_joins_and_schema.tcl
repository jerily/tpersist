package require tpersist
namespace import ::tpersist::db_*

set db [db_connect -database :memory:]
try {
    db_create_table $db [db_define_table customers {
        id {type integer primary_key 1}
        name {type text unique 1 not_null 1}
    }]
    set orders [db_define_table orders {
        id {type integer primary_key 1}
        customer_id {type integer not_null 1}
        total_cents {type integer not_null 1}
    } -foreign_keys [list [dict create columns customer_id table customers \
        referenced_columns id on_delete cascade]]]
    db_create_table $db $orders
    db_create_index $db orders_customer orders customer_id
    db_transaction $db {
        foreach {id name} {1 Alice 2 Bob 3 Carol} {
            db_execute $db [db_values [db_insert customers] [dict create id $id name $name]]
        }
        foreach {id customer amount} {1 1 1200 2 1 3400 3 2 800} {
            db_execute $db [db_values [db_insert orders] \
                [dict create id $id customer_id $customer total_cents $amount]]
        }
    }

    set query [db_select [db_table customers -as c] -columns [list \
        [db_col name -table c] \
        [db_alias [db_count [db_col id -table o]] order_count] \
        [db_alias [db_sum [db_col total_cents -table o]] spent_cents]]]
    set query [db_join $query [db_table orders -as o] \
        [db_eq [db_col id -table c] [db_col customer_id -table o]] -type left]
    set query [db_group_by $query [db_col name -table c]]
    set query [db_order_by $query [db_col name -table c]]
    db_foreach_row $db row $query {
        # Carol has no orders: the SQL NULL sum has no dictionary key.
        set amount [expr {[dict exists $row spent_cents] ? [dict get $row spent_cents] : 0}]
        puts "[dict get $row name]: [dict get $row order_count] orders, $amount cents"
    }
    set frequent [db_having $query [db_ge [db_count [db_col id -table o]] [db_value 2 -type integer]]]
    puts "Frequent customers: [dict get [db_execute $db $frequent] rows]"
} finally { db_disconnect $db }
