# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

namespace eval ::tpersist {

    variable session_counter
    variable session_var "__tpersist__session__ns__"

}

namespace eval ::tpersist::session {}

proc ::tpersist::session { action } {

    variable session_counter
    variable session_var

    if { $action ni { new done commit } } {
        return -code error "unknown session action \"$action\""
    }

    if { $action in { done commit } } {

        if { [catch [list uplevel 1 [list set $session_var]] session_ns] } {
            return -code error "session was not created in this local scope"
        }

        # Ignore inherited sessions
        if { $session_ns eq "inherited" } {
            # puts "ignore inherited session"
            if { $action eq "done" } {
                tailcall unset $session_var
            }
            return
        }

        puts "action is done..."

        if { $action eq "done" } {
            uplevel 1 [list trace remove variable $session_var unset [list ::tpersist::session::_trace_unset $session_ns]]
            uplevel 1 [list ::tpersist::_session_commit $session_ns]
            tailcall unset $session_var
        }

        # If we are here, then action is "commit"
        tailcall ::tpersist::_session_commit $session_ns

    }

    # If we are here, then action is "new"

    if { ![catch [list uplevel 1 [list set $session_var]]] } {
        return -code error "session has already been started in this local scope"
    }

    if { [_session_active] ne "" } {
        uplevel 1 [list set $session_var "inherited"]
        return
    }

    set session_id [incr session_counter]
    set session_ns "::tpersist::session::$session_id"

    puts "*** Create a new session: $session_ns"

    namespace eval $session_ns {
        variable objs
    }

    uplevel 1 [list set $session_var $session_ns]
    uplevel 1 [list trace add variable $session_var unset [list ::tpersist::session::_trace_unset $session_ns]]

}

proc ::tpersist::session::_trace_unset { session_ns args } {

    variable session_var

    # puts "In trace: $args"

    # puts "Call commit..."
    catch [list uplevel 1 [list ::tpersist::_session_commit $session_ns]]

    # puts "Session ns: $session_ns"
    namespace delete $session_ns

    # puts "Done trace."

}

proc ::tpersist::_session_commit { session_ns } {

    puts "*** Commit changes from session: $session_ns"

    upvar #0 ${session_ns}::objs objs

    if { ![info exists objs] } {
        puts "*** nothing was created/updated within the session"
        return
    }

    puts "*** Created/updated objects: $objs"

    # split objects by databases
    set dbmap [dict create]
    foreach obj $objs {

        set updated [[info object namespace $obj]::my __get_updated]
        if { ![llength $updated] } {
            puts "*** Skip not updated object: $obj"
            continue
        }

        if { $updated ne "all" } {
            return -code error "updating of individual properties has not yet been implemented"
        }

        set db [[info object class $obj] db]
        dict lappend dbmap $db $obj

    }

    set error 0

    # commit objects from each db
    dict for { db objs } $dbmap {

        if { [set error [catch [list $db transaction_begin] errmsg erropts]] } {
            set errmsg "failed to begin transaction while commiting objects from \"$db\" database: $errmsg"
        } else {

            set error [catch [list $db commit_objects $objs] errmsg erropts]
            if { $error } {
                set errmsg "failed to commit objects from \"$db\" database: $errmsg"
                break
            }

            if { $error } {
                if { [catch [list $db transaction_rollback] errmsg_more erropts] } {
                    append errmsg "; failed to rollback the transaction: $errmsg_more"
                }
            } else {
                if { [set error [catch [list $db transaction_commit] errmsg erropts]] } {
                    set errmsg "failed to commit transaction while commiting objects from \"$db\" database: $errmsg"
                }
            }

        }

        if { $error } {
            break
        }

    }

    unset objs

    if { $error } {
        return -options $erropts $errmsg
    }

}

proc ::tpersist::_session_add { object } {

    set session_ns [_session_active]
    if { $session_ns eq "" } {
        return -code error "session is required when working with the database"
    }

    upvar #0 "${session_ns}::objs" objs
    upvar #0 "${session_ns}::index" index

    # Check if the object is already registered
    if { [info exists objs] && $object in $objs } {
        return
    }

    if { [[info object namespace $object]::my __hasPK] } {
        set class [info object class $object]
        set pk    [$object getPK]
        dict set index $class $pk $object
    }

    lappend objs $object

}

proc ::tpersist::_session_get_obj { class primarykey } {

    set session_ns [_session_active]
    if { $session_ns eq "" } {
        return -code error "session is required when working with the database"
    }

    upvar #0 "${session_ns}::index" index

    if { ![info exists index] || ![dict exists $index $class] || ![dict exists $index $class $primarykey] } {
        return -code error "there is no such object in the session"
    }

    return [dict get $index $class $primarykey]

}

proc ::tpersist::_session_active { } {

    variable session_var

    # puts "In session_exists..."
    # puts "info level: [info level]"
    for { set i 1 } { $i <= [info level] } { incr i } {
        # puts "#i : [uplevel $i [list info exists $session_var]]"
        if { [uplevel $i [list info exists $session_var]] } {
            # puts "found on level: $i"
            set session_ns [uplevel $i [list set $session_var]]
            if { $session_ns ne "inherited" } {
                return $session_ns
            }
        }
    }

    return ""

}

