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

        if { $action eq "done" } {
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
        variable created
        variable updated
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

    if { ![info exists ${session_ns}::created] && ![info exists ${session_ns}::updated] } {
        return
    }

    puts "*** Commit changes from session: $session_ns"

    if { [info exists ${session_ns}::created] } {
        puts "*** Created objects: [set ${session_ns}::created]"
        unset ${session_ns}::created
    }

    if { [info exists ${session_ns}::updated] } {
        puts "*** Created objects: [set ${session_ns}::updated]"
        unset ${session_ns}::updated
    }

}

proc ::tpersist::_session_add { action object } {

    set session_ns [_session_active]
    if { $session_ns eq "" } {
        return -code error "session is required when working with the database"
    }

    if { $action eq "created" } {
        lappend ${session_ns}::created $object
    } else {
        lappend ${session_ns}::updated $object
    }

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

