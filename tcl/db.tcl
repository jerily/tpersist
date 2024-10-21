# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::Database {

    variable entityclass

    constructor { } {
        my variable entityclass
        set entityclass [info object namespace [self object]]::Entity
        ::oo::class create $entityclass
        ::oo::define $entityclass superclass ::tpersist::Entity
        ::oo::objdefine $entityclass method __db {} [list return [self object]]
    }

    method entityclass { } {
        my variable entityclass
        return $entityclass
    }

    method type_is_simple { type } {
        return [expr { $type in { string integer date bool datetime combined } }]
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
        set entities [list [my entity_get_base $entity]]
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
        set entity_base [my entity_get_base $entity]
        foreach { entity prop } [my entity_props_recursive $entity_base] {
            set opts [my entity_prop_opts $entity $prop]
            if { [my type_is_simple [dict get $opts -type]] } {
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
        dict set options -name $prop
        dict set options -base [my entity_is_base $entity]
    }

    method entity_is_base { entity } {
        my variable entityclass
        return [expr { [lindex [info class superclasses $entity] 0] eq $entityclass }]
    }

    method entity_get_base { entity } {
        while { ![my entity_is_base $entity] } {
            set entity [lindex [info class superclasses $entity] 0]
            if { $entity eq "::oo::object" } {
                return -code error "class doesn't belong to this database"
            }
        }
        return [namespace which -command $entity]
    }

    method entity_get_table { entity } {
        set entity [my entity_get_base $entity]
        set table [namespace tail $entity]
    }

    method entity_get_primarykey { entity } {
        set entity [my entity_get_base $entity]
        foreach prop [my entity_props_own $entity] {
            set opts [my entity_prop_opts $entity $prop]
            if { [dict get $opts -primarykey] } {
                return $opts
            }
        }
        return [dict create {*}{
            -auto       1
            -required   1
            -set        0
            -unique     0
            -type       "integer"
            -primarykey 1
            -name       "id"
            -base       1
        }]
    }

    method entity_get_primarykey_mapping { entity } {
        set opts [my entity_get_primarykey $entity]
        set name [dict get $opts -name]
        if { [llength $name] != 1 } {
            set name [join $name {", "}]
        }
        return "\"$name\""
    }

    method entity_is_primarykey_combined { entity } {
        return [expr { [dict get [my entity_get_primarykey $entity] -type] eq "combined" }]
    }

    method entity_get_dependencies { entity } {
        set dependencies [list]
        #puts "Data to work: [my entity_props_recursive $entity]"
        foreach { entity prop } [my entity_props_recursive $entity] {
            set opts [my entity_prop_opts $entity $prop]
            #puts "Check entity: $entity -> $prop -> $opts"
            if { [my type_is_simple [dict get $opts -type]] } {
                continue
            }
            if { [dict get $opts -set] } {
                continue
            }
            #puts "lappend dep: [dict get $opts -type]"
            set dependency [my entity_get_base ::[dict get $opts -type]]
            if { [lsearch -exact $dependencies $dependency] == -1 } {
                lappend dependencies $dependency
            }
        }
        return $dependencies
    }

    method entities_sort { entities } {
        #puts "List: $entities"
        set length [llength $entities]
        for { set i 0 } { $i < $length } { incr i } {
            set entity [lindex $entities $i]
            set dependencies [my entity_get_dependencies $entity]
            #puts "Index: $i Entity: $entity deps: $dependencies"
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
                set depencency [lindex $entities $pos]
                #puts "Move dependency: $dependency"
                set entities [lreplace $entities $pos $pos]
                set entities [linsert $entities $i $dependency]
            }
            # make sure the next iteration continues processing starting from the same index
            incr i -1
        }
        return $entities
    }

    method entities_get_many_to_many { } {
        set result [list]
        set entities [my entities_get]
        set processed [list]
        foreach { entity_base } $entities {
            foreach { entity prop } [my entity_props_recursive $entity_base] {
                set opts [my entity_prop_opts $entity $prop]
                if { [my type_is_simple [dict get $opts -type]] } {
                    continue
                }
                if { ![dict get $opts -set] } {
                    continue
                }
                set entity_ref [my entity_get_base [dict get $opts -type]]
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
                    if { [my type_is_simple $type] } {
                        continue
                    }
                    if { [my entity_get_base $type] ne $entity_base } {
                        continue
                    }
                    if { [dict get $opts_ref -set] } {
                        set need_many_to_many 1
                    } else {
                        set need_many_to_many 0
                    }
                }
                if { $need_many_to_many == -1 } {
                    return -code error "entity \"$entity_base\" depends on \"$entity_ref\",\
                        but the last one entity has no back reference"
                }
                if { !$need_many_to_many } {
                    continue
                }
                lappend result $entity_base $entity_ref
            }
            lappend processed $entity_base
        }
        return $result
    }

    method generate_helpers { } {
        foreach { entity1 entity2 } [my entities_get_many_to_many] {
            set entity1 [namespace tail $entity1]
            set entity2 [namespace tail $entity2]
            set helper_class [join [lsort [list $entity1 $entity2]] "_"]
            oo::class create $helper_class
            oo::define $helper_class [list superclass [my entityclass]]
            oo::define $helper_class [list Required [string tolower $entity1] $entity2]
            oo::define $helper_class [list Required [string tolower $entity2] $entity1]
            oo::define $helper_class [list PrimaryKey [list [string tolower $entity1] [string tolower $entity2]]]
        }
    }

}
