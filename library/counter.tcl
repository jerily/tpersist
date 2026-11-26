# SPDX-License-Identifier: MIT
# Atomic, tenant/key-scoped counters. The selected key columns must have a
# UNIQUE or PRIMARY KEY constraint; the counter must be a non-null integer.
proc ::tpersist::db_increment {handle table keys column args} {
    set prefix [_takePrefix args]
    set options [dict create -initial {} -types {}]
    if {[llength $args] % 2} {_fail ARGS "expected option/value pairs"}
    foreach {key value} $args {
        if {![dict exists $options $key]} {_fail ARGS "unknown counter option"}
        dict set options $key $value
    }
    if {![dict size $keys] || [dict exists $keys $column]} {
        _fail VALIDATION "counter requires nonempty keys separate from the counter column"
    }
    set initial [dict get $options -initial]
    foreach name [dict keys $initial] {
        if {$name eq $column || [dict exists $keys $name]} {_fail VALIDATION "initial columns must not override keys or the counter"}
    }
    set types [dict merge [dict create $column bigint] [dict get $options -types]]
    set values {}; set terms {}
    dict for {name value} [dict merge $keys $initial [dict create $column 1]] {
        set type [expr {[dict exists $types $name] ? [dict get $types $name] : "auto"}]
        dict set values $name [db_value $value -type $type]
        if {[dict exists $keys $name]} {lappend terms [db_eq [db_col $name] [dict get $values $name]]}
    }
    foreach name [dict keys $types] {
        if {![dict exists $values $name]} {_fail VALIDATION "counter type names an unknown column"}
    }
    if {$prefix ne {}} {
        set table [_prefixedTable $table [db_dialect $handle] $prefix]
    }
    set insert [db_values [db_insert $table] $values -expressions]
    set change [dict create $column [db_add \
        [db_col $column -table [dict get $insert table name]] [db_value 1 -type bigint]]]
    if {[db_dialect $handle] ne "mysql"} {
        set query [db_returning [db_on_conflict $insert [dict keys $keys] $change -expressions] $column]
        return [dict get [lindex [dict get [db_execute $handle $query] rows] 0] $column]
    }
    # MySQL cannot select an ON DUPLICATE KEY conflict target or RETURNING.
    # Update the requested key under a transaction lock, then read our own
    # value. Never update a different row merely because another UNIQUE key
    # conflicts. A concurrent first insert is retried through the same key.
    set predicate [db_and {*}$terms]
    set update [db_where [db_values [db_update $table] $change -expressions] $predicate]
    set select [db_where [db_select $table -columns [list $column]] $predicate]
    set connection [_connection $handle]
    if {[dict get $connection autobegin] && ![dict get $connection transaction]} {db_begin $handle}
    set nested [dict get [_connection $handle] transaction]
    for {set attempt 0} {$attempt < 3} {incr attempt} {
        set code [catch {
            db_transaction $handle {
                set count [dict get [db_execute $handle $update] rowcount]
                if {$count == 0} {
                    if {[catch {db_transaction $handle {db_execute $handle $insert}} message opts]} {
                        # Only a uniqueness race can be recovered in this scope.
                        if {"23000" ni [dict get $opts -errorcode]} {return -options $opts $message}
                        set count [dict get [db_execute $handle $update] rowcount]
                        if {$count == 0} {return -options $opts $message}
                    } else {set count 1}
                }
                if {$count != 1} {_fail VALIDATION "counter key must identify exactly one row"}
                set rows [dict get [db_execute $handle $select] rows]
                if {[llength $rows] != 1} {_fail VALIDATION "counter key must identify exactly one row"}
                dict get [lindex $rows 0] $column
            }
        } result opts]
        if {!$code} {return $result}
        # Retry deadlocks only when this operation owns the whole transaction.
        if {$nested || "40001" ni [dict get $opts -errorcode]} {return -options $opts $result}
    }
    return -options $opts $result
}
