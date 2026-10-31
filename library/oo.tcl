# SPDX-License-Identifier: MIT
# Optional convenience layer. The core package never sources this file.
package require TclOO
package require tpersist 0.1.0

namespace eval ::tpersist::oo { namespace export Database Query }

oo::class create ::tpersist::oo::Query {
    variable statement connection owner
    constructor {value {handle {}} {database {}}} {
        if {[dict get $value version] ne "1" || [dict get $value kind] ni {select insert update delete}} {
            return -code error -errorcode {TPERSIST VALIDATION} "expected a version 1 statement"
        }
        set statement $value
        set connection $handle
        set owner $database
    }
    method statement {} { return $statement }
    method fork {} {
        if {$owner ne {}} { return [$owner query $statement] }
        return [::tpersist::oo::Query new $statement $connection]
    }
    method compile {args} {
        if {$connection ne {}} {
            set dialect [dict get [::tpersist::_connection $connection] dialect]
            return [::tpersist::db_compile $statement -dialect $dialect {*}$args]
        }
        return [::tpersist::db_compile $statement {*}$args]
    }
    method execute {args} {
        if {$connection eq {}} {
            return -code error -errorcode {TPERSIST CONNECTION} "this query has no connection; use Database query or db_execute with its statement"
        }
        return [::tpersist::db_execute $connection $statement {*}$args]
    }
    method all {args} { return [dict get [my execute {*}$args] rows] }
    method foreach_row {varName args} {
        if {$connection eq {}} { return -code error -errorcode {TPERSIST CONNECTION} "this query has no connection" }
        tailcall ::tpersist::db_foreach_row $connection $varName $statement {*}$args
    }
}

# The wrappers mutate only their own dictionary variable. The underlying
# builders still return independent Tcl values; aliases of the OO command are
# aliases of the same mutable query, while fork creates a separate query.
namespace eval ::tpersist::oo {
    variable operation
    foreach operation {where having order_by group_by returning limit offset distinct values join clear} {
        oo::define ::tpersist::oo::Query method $operation args [format {
            set statement [::tpersist::db_%s $statement {*}$args]
            return [self]
        } $operation]
    }
    unset operation
}

oo::class create ::tpersist::oo::Database {
    variable connection queries
    constructor {args} {
        set queries {}
        set connection [::tpersist::db_connect {*}$args]
    }
    destructor {
        foreach query $queries {
            if {[info object isa typeof $query ::tpersist::oo::Query]} { $query destroy }
        }
        if {[info exists connection]} { catch {::tpersist::db_disconnect $connection} }
    }
    method connection {} { return $connection }
    method query {statement} {
        # Discard names of queries that callers already destroyed, so a
        # long-lived Database does not retain an unbounded command-name list.
        set queries [lmap query $queries {
            if {![info object isa typeof $query ::tpersist::oo::Query]} continue
            set query
        }]
        set query [::tpersist::oo::Query new $statement $connection [self]]
        lappend queries $query
        return $query
    }
    method execute {statement args} {
        if {[info object isa typeof $statement ::tpersist::oo::Query]} { set statement [$statement statement] }
        return [::tpersist::db_execute $connection $statement {*}$args]
    }
    method transaction {script} { tailcall ::tpersist::db_transaction $connection $script }
    method begin {} { ::tpersist::db_begin $connection }
    method commit {} { ::tpersist::db_commit $connection }
    method rollback {} { ::tpersist::db_rollback $connection }
    method create_table {definition args} { ::tpersist::db_create_table $connection $definition {*}$args }
    method drop_table {table args} { ::tpersist::db_drop_table $connection $table {*}$args }
    method create_index {name table columns args} { ::tpersist::db_create_index $connection $name $table $columns {*}$args }
}

namespace eval ::tpersist::oo {
    variable operation
    foreach operation {select insert update delete} {
        oo::define ::tpersist::oo::Database method $operation args [format {
            return [my query [::tpersist::db_%s {*}$args]]
        } $operation]
    }
    unset operation
}

package provide tpersist::oo [package provide tpersist]
