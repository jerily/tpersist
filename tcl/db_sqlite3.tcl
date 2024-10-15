# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::DatabaseSqlite3 {

    superclass ::tpersist::Database

    constructor { args } {
        next
    }

    method prop_type2sql { type } {
        switch -exact -- $type {
            "string"  { return "TEXT" }
            "integer" { return "INTEGER" }
            "date"    { return "DATE" }
        }
        return -code error "unknown type \"$type\""
    }

    method prop_mapping { opts } {

        if { [dict get $opts -set] } {
            return ""
        }

        set nullable [expr { ![dict get $opts -base] || ![dict get $opts -required] }]

        set output "  \"[dict get $opts -name]\""

        if { [my type_is_simple [dict get $opts -type]] } {
            append output " [my prop_type2sql [dict get $opts -type]]"
            if { !$nullable } {
                append output " NOT NULL"
            }
        } else {
            append output " INTEGER"
            if { !$nullable } {
                append output " NOT NULL"
            }
            append output " REFERENCES \"[dict get $opts -type]\" (\"id\") ON DELETE"
            if { !$nullable } {
                append output " CASCADE"
            } else {
                append output " SET NULL"
            }
        }

        append output ","

        return $output

    }

    method generate_mapping { } {

        set output [list]

        foreach entity [my get_entities] {

            lappend output "CREATE TABLE \"[namespace tail $entity]\" ("

            lappend output "  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT,"

            foreach prop [my entity_props_own $entity] {
                set add [my prop_mapping [my entity_prop_opts $entity $prop]]
                if { $add ne "" } {
                    lappend output $add
                }
            }

            if { [llength [info class subclasses $entity]] } {

                lappend output "  \"classtype\" TEXT NOT NULL,"

                set children [list]
                set tmp_children [info class subclasses $entity]

                while { [llength $tmp_children] } {

                    set child [lindex $tmp_children 0]
                    set tmp_children [lrange $tmp_children 1 end]

                    lappend children $child

                    if { [llength [info class subclasses $child]] } {
                        lappend tmp_children {*}[info class subclasses $child]
                    }

                }

                foreach child $children {
                    foreach prop [my entity_props_own $child] {
                        set add [my prop_mapping [my entity_prop_opts $child $prop]]
                        if { $add ne "" } {
                            lappend output $add
                        }
                    }
                }

            }

            lappend output ");"

        }

        return [join $output \n]

    }

}
