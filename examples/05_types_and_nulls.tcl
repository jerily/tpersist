package require tpersist
namespace import ::tpersist::db_*

set db [db_connect -database :memory:]
try {
    db_create_table $db [db_define_table records {
        id {type bigint primary_key 1}
        label {type text}
        note {type text}
        payload {type binary}
        exact_decimal {type text}
    }]
    # SQLite's numeric affinity does not guarantee exact decimal storage;
    # this example deliberately stores the exact decimal as text.
    set insert [db_values [db_insert records] [dict create \
        id [db_param id -type bigint] label [db_param label -type text] \
        note [db_param note -type text] payload [db_param payload -type binary] \
        exact_decimal [db_param decimal -type text]] -expressions]
    db_transaction $db {
        db_execute $db $insert -params [dict create id 9007199254740993 label "Zoë 世界" \
            note {} payload [binary decode hex 0001ff0041] decimal 1234567890.123456789]
        db_execute $db $insert -params [dict create id 2 label {SQL NULL} \
            payload [binary decode hex ff00] decimal 0.01] -nulls note
    }
    # db_foreach_row $db row [db_order_by [db_select records] id] { ... }
    db_foreach_row $db row [db_order_by [db_select records] -expr {id}] {
        puts "id=[dict get $row id], label=[dict get $row label]"
        puts "  note exists: [dict exists $row note]"
        puts "  bytes: [binary encode hex [dict get $row payload]]"
        puts "  exact decimal: [dict get $row exact_decimal]"
    }
} finally { db_disconnect $db }
