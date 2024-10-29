# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::Entity {

    variable __table_name__ __updated__ __primary_key__

    constructor { args } {

        my variable __updated__

        if { [catch { dict size $args } err] } {
            return -code error "arguments are not a proper dict: $err"
        }

        set entity [info object class [self object]]

        foreach options [$entity properties -required -options] {
            set prop [dict get $options -name]
            if { ![dict exists $args "-$prop"] } {
                if { [dict exists $options -default] } {
                    lappend args "-$prop" [dict get $options -default]
                    continue
                }
                if { [dict get $options -auto] } {
                    continue
                }
                return -code error "required argument \"-$prop\" missing"
            }
        }

        set myprops [$entity properties]
        set __updated__ "all"

        dict for { prop value } $args {

            if { ![string match "-*" $prop] } {
                return -code error "unknown argument \"$prop\""
            }

            set prop [string range $prop 1 end]

            if { $prop ni $myprops } {
                return -code error "unknown property \"-$prop\""
            }

            my $prop $value

        }

        ::tpersist::_session_add [self object]

    }

    method __link_many_to_many { obj1 prop1 obj2 prop2 } {

        set myclass [info object class [self object]]

        lassign [[$myclass db] helper_get_entity [info object class $obj1] $prop1 [info object class $obj2] $prop2] \
                helper_entity helper_prop1 helper_prop2

        # puts "Link $obj1 $prop1 -> $obj2 $prop2 -> $helper_entity"

        $helper_entity new -$helper_prop1 $obj1 -$helper_prop2 $obj2

    }

    method __prop { prop {value {}} {op -set} } {

        my variable __updated__
        my variable $prop

        # puts "__PROP! $prop : $value : [llength [info level 0]] : [info level 0] :"

        if { [llength [info level 0]] == 3 } {
            return [expr { [info exists $prop] ? [set $prop] : "" }]
        }

        # puts "##### Set \[$prop\]: \[$value\]"

        my __prop_validate $prop $value

        if { $__updated__ ne "all" && $prop ni $__updated__ } {
            lappend __updated__ $prop
        }

        set prop_ref [my __prop_get_many_to_many $prop]

        # if property reference type is not a many-to-many, then just set it and return
        if { $prop_ref eq "" } {
            return [set $prop $value]
        }

        # puts "set m-t-m prop $prop"

        # Here we split $op by "_". If we got a list with more than 1 elements, then $op
        # has a value "<something>_int" and set $is_internal to true. Otherwise, we will set
        # $is_internal to false.

        set op [split $op "_"]
        set is_internal [expr { [llength $op] > 1 }]
        set op [lindex $op 0]

        # if we are here, then we set a property with a many-to-many reference type
        if { $op eq "-set" } {
            # unlink all previous objects
            if { !$is_internal && [info exists $prop] } {
                foreach obj $prop {
                    $obj $prop_ref [self object] -remove_int
                }
            }
            # link new objects
            foreach obj $value {
                $obj $prop_ref [self object] -append_int
                if { !$is_internal } {
                    my __link_many_to_many [self object] $prop $obj $prop_ref
                }
            }
            return [set $prop $value]
        }

        if { $op eq "-append" } {
            # link new objects
            if { !$is_internal } {
                foreach obj $value {
                    $obj $prop_ref [self object] -append_int
                    my __link_many_to_many [self object] $prop $obj $prop_ref
                }
            }
            return [lappend $prop {*}$value]
        }

        if { $op eq "-remove" } {
            # double check that we are linked with the specified objects
            foreach obj $value {
                if { ![info exists $prop] || $obj ni [set $prop] } {
                    return -code error "object [self object] of class\
                        [info object class [self object]] is not linked with object\
                        $obj of class [info object class $obj]"
                }
                if { !$is_internal } {
                    $obj $prop_ref [self object] -remove_int
                }
                set pos [lsearch -exact [set $prop] $obj]
                set $prop [lreplace [set $prop] $pos $pos]
            }
            return [set $prop]
        }

        return -code error "unknown op: $op"

    }

    method __prop_get_many_to_many { prop } {

        set myclass [info object class [self object]]

        set opts [$myclass property $prop]

        if { ![dict get $opts -set] } {
            return ""
        }

        set type [dict get $opts -type]

        if { [::tpersist::type_is_simple $type] } {
            return ""
        }

        set entity_ref $type
        set methods [info class methods $entity_ref -all -private]
        # Filter the method list by the __PROP__* pattern
        set props [lsearch -all -inline -glob $methods "__PROP__*"]
        # Cut the prefix "__PROP__"
        set props [lmap x $props { string range $x 8 end }]

        # puts "Check : $props : of : $entity_ref :"

        foreach prop_ref $props {

            set opts_ref [$entity_ref property $prop_ref]

            # puts "Check prop $prop_ref ... $opts_ref"

            if { ![dict get $opts_ref -set] } {
                continue
            }

            set type_ref [dict get $opts_ref -type]

            if { $type_ref eq $myclass } {
                return $prop_ref
            }

        }

        return ""

    }

    method __prop_validate { prop value } {
        set myclass [info object class [self object]]
        set opts [$myclass property $prop]
        set type [dict get $opts -type]
        switch -exact -- $type {
            string {
                return 1
            }
            integer {
                # TODO
                return 1
            }
            date {
                # TODO
                return 1
            }
            bool {
                # TODO
                return 1
            }
            datetime {
                # TODO
                return 1
            }
            combined {
                return -code error "could not set a combined property"
            }
        }
        if { ![dict get $opts -set] } {
            set value [list $value]
        }
        foreach value $value {
            if { ![info object isa object $value] } {
                return -code error "property \"$prop\" accepts objects of class $type,\
                    but got not an object \"$value\""
            }
            set objclass [info object class $value]
            if { $objclass ne $type } {
                return -code error "property \"$prop\" accepts objects of class $type,\
                    but got object \"$value\" of class \"$objclass\""
            }
        }
        return 1
    }

    method __reset_updated { } {
        my variable __updated__
        set __updated__ [list]
    }

    method __get_updated { } {
        my variable __updated__
        return $__updated__
    }

    method isNull { prop } {
        my variable $prop
        return [expr { ![info exists $prop] }]
    }

    method getPK { } {
        my variable __primary_key__
        return $__primary_key__
    }

    method __setPK { value } {
        my variable __primary_key__
        set __primary_key__ $value
    }

}

::oo::class create ::tpersist::MixinEntity {

    method get { primarykey } {
        set myclass [self object]
        set props [[my db] retrieve_object $myclass $primarykey]
        #add dashes to property keys
        set props [join [lmap { k v } $props { list -$k $v }]]
        set obj [my new {*}$props]
        [info object namespace $obj]::my __reset_updated
        return $obj
    }

    method db { } {
        set myclass [self object]
        while { [catch { [info object namespace $myclass]::my db } db] } {
            set myclass [lindex [info class superclasses $myclass] 0]
            if { $myclass eq "::oo::object" } {
                return -code error "failed to get database for the class"
            }
        }
        return $db
    }

    method primarykey { } {
        set myclass [self object]
        set pk_prop_method "__PRIMARY_KEY__"
        set primarykey [lindex [info class definition [$myclass base] $pk_prop_method] 0]
        return $primarykey
    }

    method parent { } {
        set myclass [self object]
        return [lindex [info class superclasses $myclass] 0]
    }

    method base { } {
        set myclass [self object]
        set parent [set preparent [$myclass parent]]
        while { ![catch { $parent parent } parent] } {
            set myclass $preparent
            set preparent $parent
        }
        return $myclass
    }

    method is_base { } {
        set myclass [self object]
        set parent [$myclass parent]
        return [catch { $parent parent }]
    }

    method properties { args } {

        set rest $args

        set check_option [list apply [list { option varname } {
            upvar 1 rest rest
            upvar 1 $varname var
            set var [expr { $option in $rest }]
            if { $var } {
                set pos [lsearch -exact $rest $option]
                set rest [lreplace $rest $pos $pos]
            }
        }]]

        {*}$check_option -options options
        {*}$check_option -required required

        if { [llength $rest] } {
            return -code error "unknown arguments: $rest"
        }

        set myclass [self object]
        # Get all methods of the class
        set methods [info class methods $myclass -private]
        # Filter the method list by the __PROP__* pattern
        set props [lsearch -all -inline -glob $methods "__PROP__*"]
        # Cut the prefix "__PROP__"
        set props [lmap x $props { string range $x 8 end }]

        if { [my is_base] } {
            set pk [my primarykey]
            if { $pk ni $props } {
                set props [linsert $props 0 $pk]
            }
        }

        if { $required } {
            set props [lmap prop $props {
                set opts [my property $prop]
                if { ![dict get $opts -required] } {
                    continue
                }
                if { [dict get $opts -type] eq "combined" } {
                    continue
                }
                set prop $prop
            }]
        }

        if { $options } {

            # return options for each prop
            set props [lmap prop $props { my property $prop }]

        }

        if { ![my is_base] } {
            lappend props {*}[[my parent] properties {*}$args]
        }

        return $props

    }

    method property { name {option {}} } {

        set myclass [self object]
        set method "__PROP__$name"

        while { [catch { lindex [info class definition $myclass $method] 0 } options] } {

            if { ![$myclass is_base] } {
                set myclass [$myclass parent]
                continue
            }

            if { $name ne [$myclass primarykey] } {
                return -code error "unknown property \"$name\""
            }

            set options [dict create {*}{
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

        if { ![::tpersist::type_is_simple [set type [dict get $options -type]]] } {
            dict set options -type [namespace which -command $type]
        }

        dict set options -entity $myclass
        dict set options -base   [$myclass is_base]

        if { $option ne "" } {
            return [dict get $options $option]
        }

        return $options

    }

}

proc ::oo::define::Required { prop type args } {
    tailcall Property $prop {*}$args -type $type -required 1 -set 0 -primarykey 0
}

proc ::oo::define::Set { prop type args } {
    tailcall Property $prop {*}$args -type $type -required 0 -set 1 -primarykey 0
}

proc ::oo::define::Optional { prop type args } {
    tailcall Property $prop {*}$args -type $type -required 0 -set 0 -primarykey 0
}

proc ::oo::define::PrimaryKey { prop args } {
    if { [llength $prop] == 1 } {
        tailcall Property $prop {*}[lrange $args 1 end] -type [lindex $args 0] -required 1 -set 0 -primarykey 1
    } else {
        if { [llength $args] } {
            return -code error "combined primary keys don't accept custom arguments"
        }
        tailcall Property $prop -type combined -required 0 -set 0 -primarykey 1
    }
}

proc ::oo::define::Property { prop args } {

    if { [catch { dict size $args } err] } {
        return -code error "arguments are not a proper dict: $err"
    }

    set defaults [dict create {*}{
        -auto       0
        -required   0
        -set        0
        -unique     0
        -type       "string"
        -primarykey 0
    }]

    set optional {
        -default
    }

    dict for { k v } $args {
        if { ![dict exists $defaults $k] && $k ni $optional } {
           return -code error "unknown property option \"$k\""
        }
    }

    dict set args -name $prop

    set options [dict merge $defaults $args]

    set prop_method "__PROP__$prop"

    # puts "PROP:$prop OPTIONS:$options"

    if { ![catch [list uplevel 1 renamemethod $prop_method __test__existence__]] } {
        uplevel 1 renamemethod __test__existence__ $prop_method
        return -code error "property \"$prop\" is already defined"
    }

    uplevel 1 [list variable $prop]

    uplevel 1 [list method $prop_method $options {}]
    uplevel 1 [list forward $prop my __prop $prop]
    uplevel 1 [list self mixin ::tpersist::MixinEntity]

    set pk_prop_method "__PRIMARY_KEY__"

    # if current property is a primary key, then configure it as a pk
    if { [dict get $options -primarykey] } {
        uplevel 1 [list method $pk_prop_method $prop {}]
    } else {
        # if we already have a pk, then do nothing
        if { ![catch [list uplevel 1 renamemethod $pk_prop_method __test__existence__]] } {
            uplevel 1 renamemethod __test__existence__ $pk_prop_method
        } else {
            # set pk to default if we don't already have pk
            uplevel 1 [list method $pk_prop_method $prop "id"]
        }
    }

}

