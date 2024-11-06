# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::DatabaseSqlite3 {

    superclass ::tpersist::Database

    method prop_type2sql { type } {
        switch -exact -- $type {
            "string"   { return "TEXT" }
            "integer"  { return "INTEGER" }
            "date"     { return "DATE" }
            "datetime" { return "DATETIME" }
            "bool"     { return "BOOLEAN" }
        }
        return -code error "unknown type \"$type\""
    }

    method prop_mapping { opts } {

        if { [dict get $opts -set] } {
            return ""
        }

        if { [dict get $opts -primarykey] && [dict get $opts -type] eq "combined" } {
            return "  PRIMARY KEY (\"[join [dict get $opts -name] {", "}]\")"
        }

        set nullable [expr { ![dict get $opts -base] || ![dict get $opts -required] }]

        set output "  \"[dict get $opts -name]\""

        if { [::tpersist::type_is_simple [dict get $opts -type]] } {
            append output " [my prop_type2sql [dict get $opts -type]]"
            if { [dict get $opts -unique] } {
                append output " UNIQUE"
            }
            if { [dict get $opts -primarykey] } {
                append output " PRIMARY KEY"
            } elseif { !$nullable } {
                append output " NOT NULL"
            }
            if { [dict get $opts -auto] } {
                append output " AUTOINCREMENT"
            }
        } else {
            append output " INTEGER"
            if { !$nullable } {
                append output " NOT NULL"
            }
            set reference [dict get $opts -type]
            set table [my entity_get_table $reference]
            set primarykey [my entity_get_primarykey_mapping $reference]
            append output " REFERENCES \"$table\" ($primarykey) ON DELETE"
            if { !$nullable } {
                append output " CASCADE"
            } else {
                append output " SET NULL"
            }
        }

        return $output

    }

    method get_index_name { entity field } {
        return "idx_[string tolower [namespace tail $entity]]__[string tolower $field]"
    }

    method generate_mapping { } {

        my variable db

        my generate_helpers

        foreach entity [my entities_sort [my entities_get]] {

            set output [list]

            set is_primarykey_combined [my entity_is_primarykey_combined $entity]

            # primary key
            if { !$is_primarykey_combined } {
                set opts [$entity property [$entity primarykey]]
                lappend output [my prop_mapping $opts]
            }

            # other fields
            foreach prop [my entity_props_own $entity] {
                set opts [my entity_prop_opts $entity $prop]
                # skip the primary key
                if { [dict get $opts -primarykey] } {
                    continue
                }
                set add [my prop_mapping $opts]
                if { $add ne "" } {
                    lappend output $add
                }
            }

            if { [$entity is_multiclass] } {

                lappend output "  \"classtype\" TEXT NOT NULL"

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

            # primary key (combined)
            if { $is_primarykey_combined } {
                set opts [$entity property [$entity primarykey]]
                lappend output [my prop_mapping $opts]
            }

            # add commas
            for { set i 0 } { $i < ([llength $output] - 1) } { incr i } {
                set output [lreplace $output $i $i "[lindex $output $i],"]
            }

            set sql [list \
                "CREATE TABLE \"[my entity_get_table $entity]\" (" \
                {*}$output \
                ")"]

            set sql [join $sql \n]
            #puts "prepare SQL: \[$sql\]"
            set stmt [$db prepare $sql]
            set rs [$stmt execute [list]]
            set result [$rs allrows]
            if { $result ne "" } {
                return -code error "unexpected response \"$result\" while executing SQL statement: $sql"
            }
            $rs close
            $stmt close

            foreach { entity field } [my entity_get_indexes $entity] {
                set sql [format "CREATE INDEX \"%s\" ON \"%s\" (\"%s\")" \
                    [my get_index_name $entity $field] [my entity_get_table $entity] \
                    $field]
                set stmt [$db prepare $sql]
                set rs [$stmt execute [list]]
                set result [$rs allrows]
                if { $result ne "" } {
                    return -code error "unexpected response \"$result\" while executing SQL statement: $sql"
                }
                $rs close
                $stmt close
            }

        }

    }

    method commit_object { table columns values primarykey_name primarykey_value } {

        my variable db

        set placeholders [my get_values_placeholders $values]
        set values       [my get_values_dict $values]

        if { $primarykey_value eq "" } {

            set columns      [join $columns ","]
            set placeholders [join $placeholders ","]

            set sql "INSERT INTO %s(%s) VALUES (%s)"
            set sql [format $sql $table $columns $placeholders]

            if { $primarykey_name ne "" } {
                append sql " RETURNING $primarykey_name"
            }

        } else {

            # puts "colm: $columns"
            # puts "ph: $placeholders"
            set columns_to_update [lmap column $columns placeholder $placeholders {
                list "$column = $placeholder"
            }]
            # puts "before join: $columns_to_update"
            set columns_to_update [join [join $columns_to_update] ", "]
            # puts "after join: $columns_to_update"

            set sql "UPDATE %s SET %s WHERE $primarykey_name = :__primarykey__"
            set sql [format $sql $table $columns_to_update]

            dict set values "__primarykey__" $primarykey_value

        }

        set stmt [$db prepare $sql]
        # puts "SQL: $sql"
        # puts "data: $values"
        set rs [$stmt execute $values]
        set result [$rs allrows]

        $rs close
        $stmt close

        if { $primarykey_name ne "" && $primarykey_value eq "" } {
            return [dict get [lindex $result 0] $primarykey_name]
        } else {
            return ""
        }

    }

}
