# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

proc ::tpersist::type_is_simple { type } {
    return [expr { $type in {
        string
        integer
        date
        bool
        datetime
        combined
    } }]
}

::oo::class create ::tpersist::Database {

    variable entityclass db

    constructor { backend } {

        my variable entityclass
        my variable db

        if { ![info object isa object $backend] } {
            return -code error "an instance of tdbc::*::connection object is expected as argument, but got \"$backend\""
        }

        set dbmap [dict create {*}{
            ::tdbc::sqlite3::connection ::tpersist::DatabaseSqlite3
        }]

        set backend_class [info object class $backend]
        if { ![dict exists $dbmap $backend_class] } {
            return -code error "an instance of $class class was specified, but only the following classes are supported: [join [dict keys $dbmap] {, }]"
        }

        set db $backend

        ::oo::objdefine [self object] class [dict get $dbmap $backend_class]

        set entityclass [info object namespace [self object]]::Entity
        ::oo::class create $entityclass
        ::oo::define $entityclass superclass ::tpersist::Entity
        ::oo::objdefine $entityclass method db {} [list return [self object]]

    }

    method entityclass { } {
        my variable entityclass
        return $entityclass
    }

    method entities_get { } {
        my variable entityclass
        return [info class subclasses $entityclass]
    }

    method _entity_methods2props { methods } {
        # Filter the method list by the __PROP__* pattern
        set props [lsearch -all -inline -glob $methods "__PROP__*"]
        # Cut the prefix "__PROP__"
        set props [lmap x $props { string range $x 8 end }]
        return $props
    }

    method entity_props_own { entity } {
        # Get all methods of the class
        set methods [info class methods $entity -private]
        return [my _entity_methods2props $methods]
    }

    method entity_props { entity } {
        my variable entityclass
        set props [list]
        while 1 {
            # Get all methods of the class
            set props [concat [my entity_props_own $entity] $props]
            if { [my entity_is_base $entity] } {
                return $props
            }
            set entity [lindex [info class superclasses $entity] 0]
            if { $entity eq "::oo::object" } {
                return -code error "class doesn't belong to this database"
            }
        }
    }

    method entity_props_recursive { entity } {
        set result [list]
        #puts "Get recursive: $entity"
        set entities [list [$entity base]]
        #puts "Entities: $entities"
        while { [llength $entities] } {
            set entity [lindex $entities 0]
            set entities [lrange $entities 1 end]
            lappend entities {*}[info class subclasses $entity]
            foreach prop [my entity_props_own $entity] {
                #puts "Lappend $entity - $prop"
                lappend result $entity $prop
            }
        }
        return $result
    }

    method entity_get_indexes { entity } {
        set result [list]
        if { [my entity_is_primarykey_combined $entity] } {
            return $result
        }
        set entity_base [$entity base]
        foreach { entity prop } [my entity_props_recursive $entity_base] {
            set opts [my entity_prop_opts $entity $prop]
            if { [::tpersist::type_is_simple [dict get $opts -type]] } {
                continue
            }
            if { [dict get $opts -set] } {
                continue
            }
            lappend result $entity_base [dict get $opts -name]
        }
        return $result
    }

    method entity_prop_opts { entity prop } {
        set options [lindex [info class definition $entity "__PROP__$prop"] 0]
        dict set options -base [my entity_is_base $entity]
    }

    method entity_prop_column { entity prop } {
        return [dict get [my entity_prop_opts $entity $prop] -name]
    }

    method entity_is_base { entity } {
        my variable entityclass
        return [$entity is_base]
    }

    method entity_get_table { entity } {
        set entity [$entity base]
        set table [namespace tail $entity]
    }

    method entity_get_primarykey_mapping { entity } {
        set name [$entity primarykey]
        if { [llength $name] != 1 } {
            set name [join $name {", "}]
        }
        return "\"$name\""
    }

    method entity_is_primarykey_combined { entity } {
        return [expr { [$entity property [$entity primarykey] -type] eq "combined" }]
    }

    method entity_is_multiclass { entity } {
        set entity [$entity base]
        return [expr { [llength [info class subclasses $entity]] != 0 }]
    }

    method entity_get_dependencies { entity } {
        set dependencies [list]
        #puts "Data to work: [my entity_props_recursive $entity]"
        foreach { entity prop } [my entity_props_recursive $entity] {
            set opts [my entity_prop_opts $entity $prop]
            #puts "Check entity: $entity -> $prop -> $opts"
            if { [::tpersist::type_is_simple [dict get $opts -type]] } {
                continue
            }
            if { [dict get $opts -set] } {
                continue
            }
            #puts "lappend dep: [dict get $opts -type]"
            set dependency [[dict get $opts -type] base]
            if { [lsearch -exact $dependencies $dependency] == -1 } {
                lappend dependencies $dependency
            }
        }
        return $dependencies
    }

    method entities_sort { entities } {
        # puts "List: $entities"
        set length [llength $entities]
        for { set i 0 } { $i < $length } { incr i } {
            set entity [lindex $entities $i]
            set dependencies [my entity_get_dependencies $entity]
            # puts "Index: $i Entity: $entity deps: $dependencies"
            set need_to_move [list]
            foreach dependency $dependencies {
                set pos [lsearch -exact $entities $dependency]
                # dependency not found
                if { $pos == -1 } {
                    return -code error "could not find dependency \"$dependency\" of class \"$entity\""
                }
                # dependency already before the entity
                if { $pos <= $i } {
                    #puts "Check dependency $dependency index:$pos"
                    continue
                }
                #puts "Check dependency $dependency index:$pos - NEED TO MOVE"
                # add dependency to the list for movement
                lappend need_to_move $pos
            }
            # go next if we have nothing to move
            if { ![llength $need_to_move] } {
                #puts "No dependencies"
                continue
            }
            # move dependencies one by one from a larger index to a smaller one
            foreach pos [lsort -integer -decreasing $need_to_move] {
                set dependency [lindex $entities $pos]
                #puts "Move dependency: $dependency"
                set entities [lreplace $entities $pos $pos]
                set entities [linsert $entities $i $dependency]
            }
            # make sure the next iteration continues processing starting from the same index
            incr i -1
        }
        return $entities
    }

    method entities_get_many_to_many { {entities {}} } {
        set result [list]
        if { ![llength $entities] } {
            set entities [my entities_get]
        }
        set processed [list]
        foreach { entity_base } $entities {
            foreach { entity prop } [my entity_props_recursive $entity_base] {
                set opts [my entity_prop_opts $entity $prop]
                if { [::tpersist::type_is_simple [dict get $opts -type]] } {
                    continue
                }
                if { ![dict get $opts -set] } {
                    continue
                }
                set entity_ref [[dict get $opts -type] base]
                if { $entity_ref eq $entity_base } {
                    continue
                }
                if { [lsearch -exact $processed $entity_ref] != -1 } {
                    continue
                }
                set need_many_to_many -1
                foreach { prop_ref_entity prop_ref } [my entity_props_recursive $entity_ref] {
                    set opts_ref [my entity_prop_opts $prop_ref_entity $prop_ref]
                    set type [dict get $opts_ref -type]
                    if { [::tpersist::type_is_simple $type] } {
                        continue
                    }
                    if { [$type base] ne $entity_base } {
                        continue
                    }
                    if { [dict get $opts_ref -set] } {
                        set need_many_to_many 1
                    } else {
                        set need_many_to_many 0
                    }
                    break
                }
                if { $need_many_to_many == -1 } {
                    return -code error "entity \"$entity_base\" depends on \"$entity_ref\",\
                        but the last one entity has no back reference"
                }
                if { !$need_many_to_many } {
                    continue
                }
                lappend result $entity $prop $prop_ref_entity $prop_ref
            }
            lappend processed $entity_base
        }
        return $result
    }

    method generate_helpers { } {
        foreach { entity1 prop1 entity2 prop2 } [my entities_get_many_to_many] {
            # helper_get_entity will generate a helper if it is not already generated
            my helper_get_entity $entity1 $prop1 $entity2 $prop2
        }
    }

    method helper_get_entity { entity1 prop1 entity2 prop2 } {

        set entity1 [namespace tail [$entity1 base]]
        set entity2 [namespace tail [$entity2 base]]
        set helper_entity ::[join [lsort [list $entity1 $entity2]] "_"]
        set helper_prop1 [string tolower $entity1]
        set helper_prop2 [string tolower $entity2]

        if { ![info object isa class $helper_entity] } {
            oo::class create $helper_entity
            oo::define $helper_entity [list superclass [my entityclass]]
            oo::define $helper_entity [list Required $helper_prop1 $entity1]
            oo::define $helper_entity [list Required $helper_prop2 $entity2]
            oo::define $helper_entity [list PrimaryKey [list $helper_prop1 $helper_prop2]]
        }

        return [list $helper_entity $helper_prop1 $helper_prop2]

    }

    method commit_objects { objs } {

        # convert objects to their entity names
        set entities_map [list]

        foreach obj $objs {
            set entity [info object class $obj]
            set entity [$entity base]
            dict lappend entities_map $entity $obj
        }

        # sort entities according their internal dependencies
        set entities [my entities_sort [dict keys $entities_map]]

        # commit entities by their types
        foreach entity $entities {
            foreach obj [dict get $entities_map $entity] {
                my commit_object_prepare $obj
            }
        }

    }

    method transaction_begin { } {
        my variable db
        $db begintransaction
    }

    method transaction_commit { } {
        my variable db
        $db commit
    }

    method transaction_rollback { } {
        my variable db
        $db rollback
    }

    method retrieve_object { entity primarykey } {

        my variable db

        puts "retrieve entity: $entity"

        set entity_base [$entity base]
        puts "base entity: $entity_base"
        set table [my entity_get_table $entity_base]

        set columns [$entity properties]
        set col_pk [$entity primarykey]

        set sql "SELECT * FROM $table WHERE $col_pk = :primarykey"
        puts "sql: $sql"

        set stmt [$db prepare $sql]
        set rs [$stmt execute [dict create primarykey $primarykey]]
        set result [$rs allrows -as dicts]

        $rs close
        $stmt close

        puts "got: [lindex $result 0]"
        return [lindex $result 0]

    }

    method commit_object_prepare { obj } {

        set columns      [list]
        set values       [list]

        set entity [info object class $obj]
        set props_own [my entity_props $entity]
        set entity_base [$entity base]
        set pk ""

        # puts "COMMIT entity: $entity"
        # puts "COMMIT entity_base: $entity_base"

        # puts "OBJ $obj vars1: [info object variables $obj]"
        # puts "OBJ $obj vars2: [info object vars $obj]"

        foreach { entity_prop prop } [my entity_props_recursive $entity_base] {

            # Skip properties that are foreign to the entity of the object
            if { [lsearch -exact $props_own $prop] == -1 } {
                continue
            }

            set opts [my entity_prop_opts $entity_prop $prop]

            # Skip primary keys as for now
            if { [dict get $opts -primarykey] } {
                if { [dict get $opts -type] ne "combined" } {
                    set pk [dict get $opts -name]
                }
                continue
            }

            # Skip sets as for now
            if { [dict get $opts -set] } {
                continue
            }

            # Skip NULL properties
            if { [$obj isNull $prop] } {
                # puts "Null prop: $entity_prop -> $prop"
                continue
            }

            if { [::tpersist::type_is_simple [dict get $opts -type]] } {
                set value [$obj $prop]
            } else {
                set value [[$obj $prop] getPK]
            }

            lappend columns [my entity_prop_column $entity_prop $prop]
            lappend values $value

        }

        if { [llength [info class subclasses $entity_base]] } {
            lappend columns "classtype"
            lappend values $entity
        }

        set pk [my commit_object [my entity_get_table $entity_base] $columns $values $pk]
        if { $pk ne "" } {
            [info object namespace $obj]::my __setPK $pk
        }

    }

    method get_values_placeholders { values } {
        set count -1
        return [lmap x $values { set x :value[incr count] }]
    }

    method get_values_dict { values } {
        set count -1
        return [join [lmap x $values { list value[incr count] $x }]]
    }

}

# For debugging only

oo::define ::tpersist::Database {

    method dump_table { table data  } {
        set result [list]
        set row_size [dict create]
        foreach row $data {
            for { set i 0 } { $i < [llength $row] } { incr i } {
                set size [string length [lindex $row $i]]
                if { ![dict exists $row_size $i] || [dict get $row_size $i] < $size } {
                    dict set row_size $i $size
                }
            }
        }
        set splitter ""
        set format [list]
        foreach column [lsort [dict keys $row_size]] {
            lappend format "%-[dict get $row_size $column]s"
            if { [llength $splitter] } {
                append splitter "-"
            }
            append splitter [string repeat "-" [dict get $row_size $column]]
            append splitter "-+"
        }
        set format "[join $format { | }] |"
        set width [string length $splitter]

        set x "----\[ table: $table \]--"
        set c [expr { $width - [string length $x] + 1 }]
        if { $c > 0 } {
            append x [string repeat "-" $c]
        }
        lappend result $x

        lappend result [format $format {*}[lindex $data 0]]
        lappend result $splitter
        foreach row [lrange $data 1 end] {
            lappend result [format $format {*}$row]
        }
        lappend result [string repeat "-" $width]
    }

    method dump { } {

        my variable db

        set result [list]

        foreach table [dict keys [$db tables]] {
            if { $table in {sqlite_sequence} } continue
            set columns [dict keys [$db columns $table]]
            set data [list $columns]
            foreach vals [$db allrows "SELECT * FROM $table"] {
                set row [list]
                foreach column $columns {
                    if { [dict exists $vals $column] } {
                        lappend row [dict get $vals $column]
                    } else {
                        lappend row "<NULL>"
                    }
                }
                lappend data $row
            }
            lappend result "" {*}[my dump_table $table $data]
        }

        return $result

    }

}
