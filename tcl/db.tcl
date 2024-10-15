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
        return [expr { $type in { string integer date } }]
    }

    method get_entities { } {
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

    method entity_prop_opts { entity prop } {
        set options [lindex [info class definition $entity "__PROP__$prop"] 0]
        dict set options -name $prop
        dict set options -base [my entity_is_base $entity]
    }

    method entity_is_base { entity } {
        my variable entityclass
        return [expr { [lindex [info class superclasses $entity] 0] eq $entityclass }]
    }

}
