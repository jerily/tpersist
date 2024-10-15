# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::Entity {

    variable __table_name__

    constructor { args } {
        ::tpersist::_session_add created [self object]
    }

    method __prop { prop args } {

        my variable $prop

        if { ![llength $args] } {
            return [expr { [info exists $prop] ? $prop : "" }]
        }

    }

    method __prop_opts { prop } {
        set options [lindex [info class definition [self class] "__PROP__$prop"] 0]
        return $options
    }

    method __is_null { prop } {
        my variable $prop
        return [info exists $prop]
    }


}

proc ::oo::define::Required { prop type args } {
    tailcall Property $prop {*}$args -type $type -required 1 -set 0
}

proc ::oo::define::Set { prop type args } {
    tailcall Property $prop {*}$args -type $type -required 0 -set 1
}

proc ::oo::define::Optional { prop type args } {
    tailcall Property $prop {*}$args -type $type -required 0 -set 0
}

proc ::oo::define::Property { prop args } {

    # puts "PROP:$prop:ARGS:$args:"

    if { [catch { dict size $args } err] } {
        return -code error "arguments are not a proper dict: $err"
    }

    set defaults [dict create {*}{
        -required 0
        -set 0
        -unique 0
        -type "string"
    }]

    dict for { k v } $args {
        if { ![dict exists $defaults $k] } {
           return -code error "unknown property option \"$k\""
        }
    }

    set options [dict merge $defaults $args]
    set prop_method "__PROP__$prop"

    if { ![catch [list uplevel 1 renamemethod $prop_method __test__existence__]] } {
        uplevel 1 renamemethod __test__existence__ $prop_method
        return -code error "property \"$prop\" is already defined"
    }

    uplevel 1 [list variable $prop]

    uplevel 1 [list method $prop_method $options {}]
    uplevel 1 [list forward $prop __prop $prop]

}

