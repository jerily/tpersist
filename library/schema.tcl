# SPDX-License-Identifier: MIT
proc ::tpersist::_fields {dictionary allowed} {
    dict for {key value} $dictionary {
        if {$key ni $allowed} { _fail VALIDATION "unknown dictionary field: $key" }
    }
}

proc ::tpersist::_flag {dictionary key {default 0}} {
    if {![dict exists $dictionary $key]} { return $default }
    set value [dict get $dictionary $key]
    if {![string is boolean -strict $value]} { _fail VALIDATION "$key requires a boolean" }
    return [expr {!!$value}]
}

proc ::tpersist::db_define_table {name columns args} {
    if {[llength $args] % 2} { _fail ARGS "table options must be name/value pairs" }
    set result [dict create version 1 kind table_def name $name columns $columns]
    foreach {key value} $args {
        if {$key ni {-schema -primary_key -unique -foreign_keys}} { _fail ARGS "unknown table option: $key" }
        dict set result [string range $key 1 end] $value
    }
    _validateTable $result
    return $result
}

proc ::tpersist::_columnList {columns available dialect} {
    if {![llength $columns]} { _fail VALIDATION "column list cannot be empty" }
    if {[llength $columns] != [llength [lsort -unique $columns]]} { _fail VALIDATION "duplicate column in constraint or index" }
    set result {}
    foreach column $columns {
        if {$available ne {} && ![dict exists $available $column]} { _fail VALIDATION "unknown constraint column: $column" }
        lappend result [_quote $column $dialect]
    }
    return [join $result {, }]
}

proc ::tpersist::_validateTable {definition} {
    _fields $definition {version kind name schema columns primary_key unique foreign_keys}
    if {[dict get $definition version] ne "1" || [dict get $definition kind] ne "table_def"} {
        _fail VALIDATION "expected a version 1 table definition"
    }
    _quote [dict get $definition name] sqlite
    if {[dict exists $definition schema]} { _quote [dict get $definition schema] sqlite }
    set columns [dict get $definition columns]
    if {![dict size $columns]} { _fail VALIDATION "table requires at least one column" }
    set pk {}
    dict for {name spec} $columns {
        _quote $name sqlite
        _fields $spec {type length precision scale primary_key not_null unique auto_increment default}
        set type [dict get $spec type]
        if {$type ni {integer bigint real double text varchar blob binary boolean decimal date timestamp}} {
            _fail TYPE "unsupported column type: $type"
        }
        foreach flag {primary_key not_null unique auto_increment} { _flag $spec $flag }
        if {[_flag $spec primary_key]} { lappend pk $name }
        foreach key {length precision scale} {
            if {[dict exists $spec $key]} {
                set value [dict get $spec $key]
                if {![string is integer -strict $value] || $value < 0 || $value > 1000000} {
                    _fail VALIDATION "$key must be an integer between 0 and 1000000"
                }
            }
        }
        if {$type eq "varchar" && (![dict exists $spec length] || [dict get $spec length] < 1)} {
            _fail VALIDATION "varchar requires a positive length"
        }
        if {[dict exists $spec length] && $type ne "varchar"} { _fail VALIDATION "length is only valid for varchar" }
        if {([dict exists $spec precision] || [dict exists $spec scale]) && $type ne "decimal"} {
            _fail VALIDATION "precision and scale are only valid for decimal"
        }
        if {$type eq "decimal" && [dict exists $spec precision]} {
            if {[dict get $spec precision] < 1 || [dict get $spec precision] > 65} { _fail VALIDATION "decimal precision must be between 1 and 65" }
        }
        if {[dict exists $spec scale] && (![dict exists $spec precision] || [dict get $spec scale] > [dict get $spec precision])} {
            _fail VALIDATION "decimal scale requires precision and must not exceed it"
        }
        if {[_flag $spec auto_increment]} {
            if {$type ni {integer bigint} || ![_flag $spec primary_key] || [dict exists $spec default]} {
                _fail VALIDATION "auto_increment requires an integer primary key without a default"
            }
        }
    }
    if {[dict exists $definition primary_key]} {
        if {[llength $pk]} { _fail VALIDATION "specify primary_key on columns or on the table, not both" }
        set pk [dict get $definition primary_key]
        _columnList $pk $columns sqlite
    }
    if {[llength $pk] > 1} {
        foreach name $pk {
            if {[_flag [dict get $columns $name] auto_increment]} { _fail VALIDATION "composite primary keys cannot use auto_increment" }
        }
    }
    if {[dict exists $definition unique]} {
        foreach names [dict get $definition unique] { _columnList $names $columns sqlite }
    }
    if {[dict exists $definition foreign_keys]} {
        foreach fk [dict get $definition foreign_keys] {
            _fields $fk {columns table referenced_columns on_delete on_update}
            _columnList [dict get $fk columns] $columns sqlite
            _columnList [dict get $fk referenced_columns] {} sqlite
            if {[llength [dict get $fk columns]] != [llength [dict get $fk referenced_columns]]} {
                _fail VALIDATION "foreign key column counts must match"
            }
            _tableName [dict get $fk table] sqlite
            foreach action {on_delete on_update} {
                if {[dict exists $fk $action] && [dict get $fk $action] ni {cascade restrict {no action} {set null} {set default}}} {
                    _fail VALIDATION "unsupported foreign key action"
                }
            }
        }
    }
    return $pk
}

proc ::tpersist::_tableParts {table} {
    if {![catch {dict get $table node} node]} {
        _fields $table {node name schema}
        if {$node ne "table"} { _fail VALIDATION "expected a table expression" }
        return $table
    }
    if {![catch {dict get $table kind} kind] && $kind eq "table_def"} {
        set result [dict create node table name [dict get $table name]]
        if {[dict exists $table schema]} { dict set result schema [dict get $table schema] }
        return $result
    }
    return [dict create node table name $table]
}

proc ::tpersist::_tableName {table dialect} {
    set parts [_tableParts $table]
    set sql {}
    if {[dict exists $parts schema]} { append sql [_quote [dict get $parts schema] $dialect] . }
    append sql [_quote [dict get $parts name] $dialect]
    return $sql
}

# DDL defaults cannot use bound parameters. Accept only literal expression
# nodes, with independently validated and escaped SQL representations.
proc ::tpersist::_defaultSql {node dialect} {
    if {[dict get $node node] eq "null"} { _fields $node {node}; return NULL }
    _fields $node {node type value}
    if {[dict get $node node] ne "value"} { _fail VALIDATION "column default requires db_value or db_null" }
    set type [dict get $node type]
    set value [dict get $node value]
    switch -- $type {
        integer - bigint {
            if {![string is entier -strict $value]} { _fail TYPE "invalid integer default" }
            set value [expr {$value + 0}]
            if {$value < -9223372036854775808 || $value > 9223372036854775807} { _fail TYPE "integer default is out of range" }
            return $value
        }
        real - double - decimal {
            if {![regexp {^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$} $value]} {
                _fail TYPE "invalid numeric default"
            }
            return $value
        }
        boolean {
            if {![string is boolean -strict $value]} { _fail TYPE "invalid boolean default" }
            return [expr {$value ? "TRUE" : "FALSE"}]
        }
        auto - text - date - timestamp {
            if {[string first \x00 $value] >= 0} { _fail VALIDATION "text defaults cannot contain NUL" }
            if {$dialect eq "mysql" && [string first \\ $value] >= 0} {
                return "X'[binary encode hex [encoding convertto utf-8 $value]]'"
            }
            if {$dialect eq "postgresql"} {
                return "E'[string map [list \\ \\\\ ' ''] $value]'"
            }
            return "'[string map [list ' ''] $value]'"
        }
        default { _fail UNSUPPORTED "unsupported default type: $type" }
    }
}

proc ::tpersist::_createTableSql {definition dialect ifNotExists} {
    set pk [_validateTable $definition]
    set pieces {}
    dict for {name spec} [dict get $definition columns] {
        set type [dict get $spec type]
        switch -- $type {
            binary - blob { set sqlType [expr {$dialect eq "postgresql" ? "BYTEA" : "BLOB"}] }
            double { set sqlType [expr {$dialect eq "mysql" ? "DOUBLE" : "DOUBLE PRECISION"}] }
            varchar { set sqlType "VARCHAR([dict get $spec length])" }
            decimal {
                set sqlType DECIMAL
                if {[dict exists $spec precision]} {
                    append sqlType ([dict get $spec precision]
                    if {[dict exists $spec scale]} { append sqlType ,[dict get $spec scale] }
                    append sqlType )
                }
            }
            default { set sqlType [string toupper $type] }
        }
        set sql "[_quote $name $dialect] $sqlType"
        if {[_flag $spec auto_increment]} {
            switch -- $dialect {
                sqlite {
                    if {$type ne "integer"} { _fail UNSUPPORTED "SQLite auto_increment requires type integer" }
                    append sql { PRIMARY KEY AUTOINCREMENT}
                }
                postgresql { append sql { GENERATED BY DEFAULT AS IDENTITY} }
                mysql { append sql { AUTO_INCREMENT} }
            }
        }
        if {[_flag $spec not_null]} { append sql { NOT NULL} }
        if {[_flag $spec unique]} { append sql { UNIQUE} }
        if {[dict exists $spec default]} { append sql " DEFAULT [_defaultSql [dict get $spec default] $dialect]" }
        lappend pieces $sql
    }
    if {[llength $pk]} {
        set inline [expr {$dialect eq "sqlite" && [llength $pk] == 1 && [_flag [dict get $definition columns [lindex $pk 0]] auto_increment]}]
        if {!$inline} { lappend pieces "PRIMARY KEY ([_columnList $pk [dict get $definition columns] $dialect])" }
    }
    if {[dict exists $definition unique]} {
        foreach names [dict get $definition unique] {
            lappend pieces "UNIQUE ([_columnList $names [dict get $definition columns] $dialect])"
        }
    }
    if {[dict exists $definition foreign_keys]} {
        foreach fk [dict get $definition foreign_keys] {
            set sql "FOREIGN KEY ([_columnList [dict get $fk columns] {} $dialect]) REFERENCES [_tableName [dict get $fk table] $dialect] ([_columnList [dict get $fk referenced_columns] {} $dialect])"
            foreach action {on_delete on_update} {
                if {[dict exists $fk $action]} {
                    set value [dict get $fk $action]
                    if {$dialect eq "mysql" && $value eq "set default"} { _fail UNSUPPORTED "MySQL does not support SET DEFAULT foreign key actions" }
                    append sql " [string toupper [string map {_ { }} $action]] [string toupper $value]"
                }
            }
            lappend pieces $sql
        }
    }
    set sql {CREATE TABLE }
    if {$ifNotExists} { append sql {IF NOT EXISTS } }
    append sql [_tableName $definition $dialect] " (" [join $pieces {, }] ")"
    if {$dialect eq "mysql"} { append sql { ENGINE=InnoDB} }
    return $sql
}

proc ::tpersist::db_schema_sql {definition args} {
    if {[llength $args] ni {0 2} || ([llength $args] && [lindex $args 0] ne "-dialect")} {
        _fail ARGS "expected: db_schema_sql definition ?-dialect sqlite|postgresql|mysql?"
    }
    set dialect [expr {[llength $args] ? [_dialect [lindex $args 1]] : "sqlite"}]
    return [_createTableSql $definition $dialect 0]
}

proc ::tpersist::_ddl {handle sql} {
    set c [_connection $handle]
    if {[dict get $c dialect] eq "mysql" && [dict get $c transaction]} {
        _fail TRANSACTION "MySQL schema commands require no active transaction because DDL can commit implicitly"
    }
    _raw $handle $sql
    return
}

proc ::tpersist::_ddlOption {args name} {
    if {![llength $args]} { return 0 }
    if {[llength $args] != 2 || [lindex $args 0] ne $name || ![string is boolean -strict [lindex $args 1]]} {
        _fail ARGS "expected $name boolean"
    }
    return [expr {!![lindex $args 1]}]
}

proc ::tpersist::db_create_table {handle definition args} {
    set flag [_ddlOption $args -if_not_exists]
    _ddl $handle [_createTableSql $definition [dict get [_connection $handle] dialect] $flag]
}

proc ::tpersist::db_drop_table {handle table args} {
    set flag [_ddlOption $args -if_exists]
    set dialect [dict get [_connection $handle] dialect]
    set sql {DROP TABLE }
    if {$flag} { append sql {IF EXISTS } }
    append sql [_tableName $table $dialect]
    _ddl $handle $sql
}

proc ::tpersist::db_create_index {handle name table columns args} {
    if {[llength $args] % 2} { _fail ARGS "index options must be name/value pairs" }
    set flags {unique 0 if_not_exists 0}
    foreach {key value} $args {
        if {$key ni {-unique -if_not_exists}} { _fail ARGS "unknown index option: $key" }
        dict set flags [string range $key 1 end] $value
    }
    set unique [_flag $flags unique]
    set exists [_flag $flags if_not_exists]
    set dialect [dict get [_connection $handle] dialect]
    if {$exists && $dialect eq "mysql"} { _fail UNSUPPORTED "MySQL CREATE INDEX does not support IF NOT EXISTS" }
    set indexName [_quote $name $dialect]
    set parts [_tableParts $table]
    if {$dialect eq "sqlite" && [dict exists $parts schema]} {
        set indexName "[_quote [dict get $parts schema] $dialect].$indexName"
        dict unset parts schema
    }
    set sql {CREATE }
    if {$unique} { append sql {UNIQUE } }
    append sql {INDEX }
    if {$exists} { append sql {IF NOT EXISTS } }
    append sql "$indexName ON [_tableName $parts $dialect] ([_columnList $columns {} $dialect])"
    _ddl $handle $sql
}

namespace eval ::tpersist { namespace export db_* }
