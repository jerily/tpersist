# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {}

::oo::class create ::tpersist::Entity {

    variable __table_name__

    constructor { args } {

        if { [catch { dict size $args } err] } {
            return -code error "arguments are not a proper dict: $err"
        }

        foreach prop [my __get_props_required] {
            if { ![dict exists $args "-$prop"] } {
                if { [my __prop_has_default $prop] } {
                    lappend args "-$prop" [my __prop_get_default $prop]
                } elseif { ![my __prop_is_auto $prop] } {
                    return -code error "required argument \"-$prop\" missing"
                }
            }
        }

        set myprops [my __get_props]

        dict for { prop value } $args {

            if { ![string match "-*" $prop] } {
                return -code error "unknown argument \"$prop\""
            }

            set prop [string range $prop 1 end]

            if { [lsearch -exact $myprops $prop] == -1 } {
                return -code error "unknown argument \"-$prop\""
            }

            my $prop $value

        }


        ::tpersist::_session_add created [self object]

    }

    method __prop { prop {value {}} } {

        my variable $prop

        if { [llength [info level 0]] == 1 } {
            return [expr { [info exists $prop] ? $prop : "" }]
        }

        puts "Set \[$prop\]: \[$value\]"

        my __prop_validate $prop $value

        set $prop $value

    }

    method __prop_validate { prop value } {
        set opts [my __get_prop $prop]
        set type [my __prop_get_type $prop]
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

    method __get_props { {own {}} } {
        set myclass [info object class [self object]]
        if { $own eq "" } {
            set methods [info class methods $myclass -all -private]
        } elseif { $own ne "-own" } {
            return -code error "unknown flag \"$own\" where \"-own\" is expected"
        } else {
            set methods [info class methods $myclass -private]
        }
        # Filter the method list by the __PROP__* pattern
        set props [lsearch -all -inline -glob $methods "__PROP__*"]
        # Cut the prefix "__PROP__"
        set props [lmap x $props { string range $x 8 end }]
        return $props
    }

    method __get_prop { prop } {
        set myclass [info object class [self object]]
        set method "__PROP__$prop"
        while { [catch { info class definition $myclass $method } options] } {
            set myclass [lindex [info class superclasses $myclass] 0]
            if { $myclass eq "::oo::object" } {
                return -code error "unknown property \"$prop\""
            }
        }
        set options [lindex $options 0]
        return $options
    }

    method __get_props_required { {own {}} } {
        set result [list]
        foreach prop [my __get_props $own] {
            if { [dict get [my __get_prop $prop] -required] } {
                lappend result $prop
            }
        }
        return $result
    }

    method __prop_has_default { prop } {
        return [dict exists [my __get_prop $prop] -default]
    }

    method __prop_get_default { prop } {
        return [dict get [my __get_prop $prop] -default]
    }

    method __prop_get_type { prop } {
        set opts [my __get_prop $prop]
        set type [dict get $opts -type]
        if { ![::tpersist::type_is_simple $type] } {
            set type [namespace which -command $type]
        }
        return $type
    }

    method __prop_is_simple { prop } {
        return [::tpersist::type_is_simple [dict get [my __get_prop $prop] -type]]
    }

    method __prop_is_auto { prop } {
        return [dict get [my __get_prop $prop] -auto]
    }

    method __is_null { prop } {
        my variable $prop
        return [info exists $prop]
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
        tailcall Property $prop -type combined -required 1 -set 0 -primarykey 1
    }
}

proc ::oo::define::Property { prop args } {

    # puts "PROP:$prop:ARGS:$args:"

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
        if { ![dict exists $defaults $k] && [lsearch -exact $optional $k] == -1 } {
           return -code error "unknown property option \"$k\""
        }
    }

    dict set args -name $prop

    set options [dict merge $defaults $args]
    set prop_method "__PROP__$prop"

    if { ![catch [list uplevel 1 renamemethod $prop_method __test__existence__]] } {
        uplevel 1 renamemethod __test__existence__ $prop_method
        return -code error "property \"$prop\" is already defined"
    }

    uplevel 1 [list variable $prop]

    uplevel 1 [list method $prop_method $options {}]
    uplevel 1 [list forward $prop my __prop $prop]

}

