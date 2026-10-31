# SPDX-License-Identifier: MIT
namespace eval ::tpersist {
    variable connections {}
    variable serial 0
}

proc ::tpersist::_fail {code message} {
    return -code error -errorcode [list TPERSIST $code] $message
}

proc ::tpersist::_connection {handle} {
    variable connections
    if {![dict exists $connections $handle]} {
        _fail CONNECTION "unknown or closed connection handle"
    }
    return [dict get $connections $handle]
}

proc ::tpersist::_dialect {dialect} {
    if {$dialect ni {sqlite postgresql mysql}} {
        _fail DIALECT "dialect must be sqlite, postgresql, or mysql"
    }
    return $dialect
}

proc ::tpersist::_quote {name dialect} {
    if {$name eq {} || [string first \x00 $name] >= 0} {
        _fail VALIDATION "identifiers must be nonempty and contain no NUL characters"
    }
    set q [expr {$dialect eq "mysql" ? "`" : "\""}]
    return $q[string map [list $q $q$q] $name]$q
}

proc ::tpersist::db_connect {args} {
    variable connections
    variable serial
    if {[llength $args] % 2} { _fail ARGS "connection options must be name/value pairs" }
    set dialect sqlite
    set autobegin 1
    set database {}
    set options {}
    foreach {key val} $args {
        switch -- $key {
            -dialect { set dialect [_dialect $val] }
            -database { set database $val }
            -autobegin {
                if {![string is boolean -strict $val]} { _fail ARGS "-autobegin requires a boolean" }
                set autobegin [expr {!!$val}]
            }
            default { lappend options $key $val }
        }
    }
    set driver [dict get {sqlite sqlite3 postgresql postgres mysql mysql} $dialect]
    if {[catch {package require tdbc::$driver} result optionsDict]} {
        return -code error -errorcode [list TPERSIST DRIVER $driver] \
            "cannot load tdbc::$driver: $result"
    }
    if {$dialect eq "sqlite"} {
        if {$database eq {}} { _fail ARGS "SQLite requires -database (use :memory: for an in-memory database)" }
        set command [::tdbc::sqlite3::connection new $database {*}$options]
    } else {
        set normalized {}
        foreach {key val} $options {
            if {$dialect eq "mysql" && $key eq "-password"} { set key -passwd }
            lappend normalized $key $val
        }
        if {$database ne {}} { lappend normalized -database $database }
        set command [::tdbc::${driver}::connection new {*}$normalized]
    }
    set handle tpersist:db[incr serial]
    dict set connections $handle [dict create command $command dialect $dialect \
        transaction 0 savepoints {} autobegin $autobegin]
    try {
        if {$dialect eq "sqlite"} { _raw $handle {PRAGMA foreign_keys = ON} }
    } on error {message opts} {
        catch {$command close}
        dict unset connections $handle
        return -options $opts $message
    }
    return $handle
}

proc ::tpersist::db_disconnect {handle} {
    variable connections
    set c [_connection $handle]
    [dict get $c command] close
    dict unset connections $handle
    return
}

# Always supply a dictionary: TDBC must never look up bind variables in a
# caller's scope. Statements and result sets remain owned by this adapter.
proc ::tpersist::_raw {handle sql} {
    set db [dict get [_connection $handle] command]
    set statement [$db prepare $sql]
    try {
        set rs [$statement execute {}]
        try { return [$rs allrows -as dicts] } finally { $rs close }
    } finally { $statement close }
}

proc ::tpersist::_prepare {handle statement options} {
    set c [_connection $handle]
    if {[llength $options] % 2} { _fail ARGS "execution options must be name/value pairs" }
    foreach {key value} $options {
        if {$key ni {-params -nulls}} { _fail ARGS "unknown execution option: $key" }
    }
    set compiled [db_compile $statement -dialect [dict get $c dialect] {*}$options]
    if {[llength [dict get $compiled required]]} {
        _fail PARAMETER "missing parameters: [join [dict get $compiled required] {, }]"
    }
    if {[dict get $c autobegin] && ![dict get $c transaction]} { db_begin $handle }
    set command [[dict get $c command] prepare [dict get $compiled sql]]
    try {
        dict for {name type} [dict get $compiled types] {
            if {$type eq "auto"} continue
            set type [dict get {text varchar integer bigint bigint bigint real double \
                double double boolean bit binary varbinary decimal decimal \
                date date timestamp timestamp} $type]
            $command paramtype $name $type
        }
        set rs [$command execute [dict get $compiled params]]
        set columns [$rs columns]
        if {[llength $columns] != [llength [lsort -unique $columns]]} {
            $rs close
            _fail COLUMNS "duplicate result column names; use db_alias to give them unique names"
        }
        return [list $command $rs $columns]
    } on error {message opts} {
        catch {$command close}
        return -options $opts $message
    }
}

proc ::tpersist::db_execute {handle statement args} {
    lassign [_prepare $handle $statement $args] command rs columns
    try {
        set rowcount [expr {[dict get $statement kind] eq "select" ? -1 : [$rs rowcount]}]
        set rows [$rs allrows -as dicts]
        return [dict create columns $columns rows $rows rowcount $rowcount]
    } finally {
        try { $rs close } finally { $command close }
    }
}

proc ::tpersist::db_foreach_row {handle varName statement args} {
    if {![llength $args]} { _fail ARGS "expected a row-processing script" }
    set script [lindex $args end]
    set options [lrange $args 0 end-1]
    upvar 1 $varName row
    lassign [_prepare $handle $statement $options] command rs columns
    set count 0
    try {
        while {[$rs nextdict row]} {
            incr count
            set code [catch {uplevel 1 $script} result opts]
            switch -- $code {
                0 - 4 { continue }
                3 { break }
                2 {
                    dict incr opts -level
                    return -options $opts $result
                }
                default { return -options $opts $result }
            }
        }
    } finally {
        try { $rs close } finally { $command close }
    }
    return $count
}

proc ::tpersist::db_begin {handle} {
    variable connections
    set c [_connection $handle]
    if {[dict get $c transaction]} { _fail TRANSACTION "transaction already active; use a savepoint or db_transaction" }
    [dict get $c command] begintransaction
    dict set connections $handle transaction 1
    return
}

proc ::tpersist::db_commit {handle} {
    variable connections
    set c [_connection $handle]
    if {![dict get $c transaction]} { _fail TRANSACTION "no active transaction" }
    [dict get $c command] commit
    dict set connections $handle transaction 0
    dict set connections $handle savepoints {}
    return
}

proc ::tpersist::db_rollback {handle} {
    variable connections
    set c [_connection $handle]
    if {![dict get $c transaction]} { _fail TRANSACTION "no active transaction" }
    [dict get $c command] rollback
    dict set connections $handle transaction 0
    dict set connections $handle savepoints {}
    return
}

proc ::tpersist::db_savepoint {handle name} {
    variable connections
    set c [_connection $handle]
    if {![dict get $c transaction]} { _fail TRANSACTION "savepoint requires an active transaction" }
    set stack [dict get $c savepoints]
    if {$name in $stack} { _fail TRANSACTION "savepoint name is already active" }
    _raw $handle "SAVEPOINT [_quote $name [dict get $c dialect]]"
    lappend stack $name
    dict set connections $handle savepoints $stack
    return
}

proc ::tpersist::_savepointTop {handle name} {
    set c [_connection $handle]
    set stack [dict get $c savepoints]
    if {![llength $stack] || [lindex $stack end] ne $name} {
        _fail TRANSACTION "savepoints must be released or rolled back in reverse creation order"
    }
    return $c
}

proc ::tpersist::db_rollback_to {handle name} {
    set c [_savepointTop $handle $name]
    _raw $handle "ROLLBACK TO SAVEPOINT [_quote $name [dict get $c dialect]]"
    return
}

proc ::tpersist::db_release {handle name} {
    variable connections
    set c [_savepointTop $handle $name]
    _raw $handle "RELEASE SAVEPOINT [_quote $name [dict get $c dialect]]"
    dict set connections $handle savepoints [lrange [dict get $c savepoints] 0 end-1]
    return
}

proc ::tpersist::db_transaction {handle script} {
    variable serial
    set nested [dict get [_connection $handle] transaction]
    if {$nested} {
        set name tpersist_scope_[incr serial]
        db_savepoint $handle $name
    } else { db_begin $handle }
    set code [catch {uplevel 1 $script} result opts]
    # A plain return commits, but return -code error/custom is a failure even
    # though catch initially reports TCL_RETURN. Preserve its eventual code.
    set successful [expr {$code in {0 3 4} || ($code == 2 && [dict get $opts -code] in {0 2 3 4})}]
    if {$successful} {
        set commitCode [catch {
            if {$nested} { db_release $handle $name } else { db_commit $handle }
        } commitResult commitOpts]
        if {$commitCode} {
            set successful 0
            set code $commitCode; set result $commitResult; set opts $commitOpts
        }
    }
    if {!$successful} {
        # Preserve the original error even when a driver has already rolled back.
        catch {
            if {$nested} {
                db_rollback_to $handle $name
                db_release $handle $name
            } else { db_rollback $handle }
        }
    }
    if {$code in {2 3 4}} { dict incr opts -level }
    return -options $opts $result
}
