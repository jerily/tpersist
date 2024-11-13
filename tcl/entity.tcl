# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::Entity {

    variable __table_name__ __updated__ __status__ __primary_key__

    destructor {

        if { [my __get_status] eq "dead" } {
            #puts "Destroy dead obj: [self object]"
            return
        }

        # In case of many-to-many relationship, we need to remove this object
        # from the linked objects. In order to do that, we will go through all
        # properties. For many-to-many properties, we will set them to empty
        # list. This will remove this object from the linked objects.

        set entity [info object class [self object]]
        foreach prop [$entity properties] {
            set prop_ref [my __prop_get_many_to_many $prop]
            # prop_ref is not empty only if the property has many-to-many
            # relationships.
            if { $prop_ref ne "" } {
                # Set the property as an empty list
                my $prop [list] -set
            }
        }

        ::tpersist::_session_del [self object]

    }

    constructor { args } {

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

        my __set_status "new"
        my __reset_updated

        set myprops [$entity properties]

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

        return [$helper_entity new -$helper_prop1 $obj1 -$helper_prop2 $obj2]

    }

    method __unlink_many_to_many { obj1 prop1 obj2 prop2 } {

        set myclass [info object class [self object]]

        lassign [[$myclass db] helper_get_entity [info object class $obj1] $prop1 [info object class $obj2] $prop2] \
                helper_entity helper_prop1 helper_prop2

        # puts "Unlink $obj1 $prop1 -> $obj2 $prop2 -> $helper_entity"

        foreach obj [info class instances $helper_entity] {
            if { [$obj $helper_prop1] eq $obj1 && [$obj $helper_prop2] eq $obj2 } {
                $obj destroy
                return
            }
        }

        return -code error "could not find instance of helper entity $helper_entity\
            that links $obj1->$prop1 and $obj2->$prop2"

    }

    method __update_set { prop } {

        set myobj [self object]
        set myclass [info object class $myobj]
        set opts [$myclass property $prop]
        set myprimarykey [my getPK]

        set entity_ref [dict get $opts -type]
        set prop_ref [my __prop_get_one_to_many $prop]

        # puts "Update set: $prop -> $opts -> $entity_ref -> $prop_ref"

        set is_many_to_many [$entity_ref property $prop_ref -set]

        if { $is_many_to_many } {
            set ids [[$myclass db] retrieve_pk_many_to_many $myprimarykey $myclass $prop $entity_ref $prop_ref]
        } else {
            set ids [[$myclass db] retrieve_pk_one_to_many $myprimarykey $entity_ref $prop_ref]
        }

        switch -exact -- [llength $ids] {
            0 { set result [list] }
            1 {
                set result [list [$entity_ref get [lindex $ids 0]]]
            }
            default {
                set result [$entity_ref get {*}$ids]
            }
        }

        if { $is_many_to_many } {
            foreach linked_obj $result {
                set helper_obj [my __link_many_to_many $myobj $prop $linked_obj $prop_ref]
                [info object namespace $helper_obj]::my __set_status "loaded"
            }
        }

        return $result

    }

    method __prop_remove { __prop__ __value__ } {
        my variable $__prop__
        if { [my __prop_exists $__prop__] } {
            if { [set __pos__ [lsearch -exact [set $__prop__] $__value__]] != -1 } {
                my __prop_set $__prop__ [lreplace [set $__prop__] $__pos__ $__pos__]
            }
        }
    }

    method __prop_append { __prop__ args } {

        # Make sure that we don't have the "args" variable to be able
        # to handle the "args" property name
        set __value__ $args
        unset -nocomplain args

        my variable $__prop__

        return [lappend $__prop__ {*}$__value__]

    }

    method __prop_get { __prop__ } {
        my variable $__prop__
        return [set $__prop__]
    }

    method __prop_set { __prop__ __value__ } {
        my variable $__prop__
        return [set $__prop__ $__value__]
    }

    method __prop_exists { __prop__ } {
        my variable $__prop__
        return [info exists $__prop__]
    }

    method __prop { prop {value {}} {op -set} } {

        my variable __updated__

        set myclass [info object class [self object]]
        set opts [$myclass property $prop]

        # puts "__PROP! $prop : $value : [llength [info level 0]] : [info level 0] :"

        if { [llength [info level 0]] == 3 } {

            if { [dict get $opts -set] } {
                if { ![my __prop_exists $prop] } {
                    my __prop_set $prop [my __update_set $prop]
                }
                return [my __prop_get $prop]
            }

            return [expr { [my __prop_exists $prop] ? [my __prop_get $prop] : "" }]

        }

        # puts "##### Set \[$prop\]: \[$value\]"

        my __prop_validate $prop $value

        set prop_ref [my __prop_get_many_to_many $prop]

        # if property reference type is not a many-to-many, then just set it and return
        if { $prop_ref eq "" } {

            # Do nothing if the property has a value and it is the same as the one
            # we are trying to set
            if { [my __prop_exists $prop] && [my __prop_get $prop] eq $value } {
                return $value
            }

            if { [dict get $opts -primarykey] } {
                my __setPK $value
            }

            if { [my __get_status] eq "loaded" } {
                lappend __updated__ $prop
            }

            return [my __prop_set $prop $value]

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
            if { !$is_internal && [my __prop_exists $prop] } {
                foreach obj [my __prop_get $prop] {
                    # We must not break an existing link with the object that
                    # is specified in the set value. Instead, we will remove that object
                    # from the set value.
                    if { $obj in $value } {
                        set pos [lsearch -exact $value $obj]
                        set value [lreplace $value $pos $pos]
                    } else {
                        $obj $prop_ref [self object] -remove_int
                        my __unlink_many_to_many [self object] $prop $obj $prop_ref
                    }
                }
            }
            # link new objects
            foreach obj $value {
                $obj $prop_ref [self object] -append_int
                if { !$is_internal } {
                    my __link_many_to_many [self object] $prop $obj $prop_ref
                }
            }
            return [my __prop_append $prop {*}$value]
        }

        if { $op eq "-append" } {
            # link new objects
            if { !$is_internal } {
                # first let's remove objects that are already linked from the values
                if { [my __prop_exists $prop] } {
                    foreach obj [my __prop_get $prop] {
                        set pos [lsearch -exact $value $obj]
                        if { $pos != -1 } {
                            set value [lreplace $value $pos $pos]
                        }
                    }
                }
                foreach obj $value {
                    $obj $prop_ref [self object] -append_int
                    my __link_many_to_many [self object] $prop $obj $prop_ref
                }
            }
            return [my __prop_append $prop {*}$value]
        }

        if { $op eq "-remove" } {
            # double check that we are linked with the specified objects
            foreach obj $value {
                if { ![my __prop_exists $prop] || $obj ni [my __prop_get $prop] } {
                    return -code error "object [self object] of class\
                        [info object class [self object]] is not linked with object\
                        $obj of class [info object class $obj]"
                }
                if { !$is_internal } {
                    $obj $prop_ref [self object] -remove_int
                    my __unlink_many_to_many [self object] $prop $obj $prop_ref
                }
                my __prop_remove $prop $obj
            }
            return [my __prop_get $prop]
        }

        return -code error "unknown op: $op"

    }

    method __prop_get_one_to_many { prop } {

        set myclass [info object class [self object]]
        set opts [$myclass property $prop]
        set type [dict get $opts -type]

        set entity_ref $type
        foreach prop_ref [$entity_ref properties] {

            set opts_ref [$entity_ref property $prop_ref]

            set type_ref [dict get $opts_ref -type]

            if { $type_ref eq $myclass } {
                return $prop_ref
            }

        }

        return -code error "could not find one-to-many relationship between $myclass and $entity_ref"

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
        foreach prop_ref [$entity_ref properties] {

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

    method __set_status { status } {
        my variable __status__
        set __status__ $status
    }

    method __get_status { } {
        my variable __status__
        return $__status__
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

    method __hasPK { } {
        my variable __primary_key__
        return [info exists __primary_key__]
    }

    method __hasCombinedPK { } {
        set myclass [info object class [self object]]
        return [$myclass is_primarykey_combined]
    }

}

::oo::class create ::tpersist::MixinEntity {

    method select { {where {}} {values {}} } {
        set myclass [self object]
        set primarykeys [[my db] retrieve_pk_select $myclass $where $values]
        switch -exact -- [llength $primarykeys] {
            0 { return [list] }
            1 {
                return [list [my get [lindex $primarykeys 0]]]
            }
            default {
                return [my get {*}$primarykeys]
            }
        }
    }

    method get { args } {

        if { ![llength $args] } {
            return -code error "no primary key(s) specified"
        }

        set myclass [self object]

        # If we have multiple primary keys, then return all objects as a list
        if { [llength $args] > 1 } {
            return [lmap primarykey $args { $myclass get $primarykey }]
        }

        set primarykey [lindex $args 0]

        # Check if we already have an object with the desired class and
        # primary key in the session cache
        if { ![catch [list ::tpersist::_session_get_obj $myclass $primarykey] obj] } {
            # puts "*** Return an object from session cache: $obj"
            return $obj
        }

        set props [[my db] retrieve_object $myclass $primarykey]

        # Get objects on which the current object depends
        dict for { prop value } $props {

            # skip empty values
            if { $value eq "" } {
                continue
            }

            set opts [my property $prop]

            # skip the primary key
            if { [dict get $opts -primarykey] } {
                continue
            }

            # skip simple types
            set type [dict get $opts -type]
            if { [::tpersist::type_is_simple $type] } {
                continue
            }

            # skip sets as for now
            if { [dict get $opts -set] } {
                continue
            }

            dict set props $prop [$type get $value]

        }

        #add dashes to property keys
        set props [join [lmap { k v } $props { list -$k $v }]]

        set obj [my new {*}$props]
        [info object namespace $obj]::my __set_status "loaded"

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

    method children { } {
        set myclass [self object]
        return [info class subclasses $myclass]
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

    method is_multiclass { } {
        set mybase [my base]
        return [expr { [llength [info class subclasses $mybase]] != 0 }]
    }

    method is_primarykey_combined { } {
        set primarykey [my primarykey]
        return [expr { [llength [split $primarykey]] > 1 }]
    }

    method properties { args } {

        set rest $args
        set myclass [self object]

        set check_option [list apply [list { option varname } {
            upvar 1 rest rest
            upvar 1 $varname var
            set var [expr { $option in $rest }]
            if { $var } {
                set pos [lsearch -exact $rest $option]
                set rest [lreplace $rest $pos $pos]
            }
        }]]

        {*}$check_option -own own
        {*}$check_option -all all

        if { $all } {

            if { $own } {
                return -code error "-all and -own arguments are mutually exclusive"
            }

            set result [list]
            set entities [list [my base]]

            while { [llength $entities] } {
                set entity [lindex $entities 0]
                set entities [lrange $entities 1 end]
                lappend entities {*}[$entity children]
                lappend result {*}[$entity properties -own {*}$rest]
            }

            return $result

        }


        {*}$check_option -options options
        {*}$check_option -required required

        if { [llength $rest] } {
            return -code error "unknown arguments: $rest"
        }

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

        if { !$own && ![my is_base] } {
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
    if { [llength [split $prop]] == 1 } {
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

