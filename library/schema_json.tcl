# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Load and apply versioned JSON schemas using tjson.
# Normalize tjson's UTF-8 strings to Tcl's representation, including Tcl 8.6.
proc ::tpersist::_schemaText {text} {
    return [encoding convertfrom utf-8 [encoding convertto utf-8 $text]]
}

# Keep tjson handles until validation finishes: its simple/typed conversions
# collapse JSON null and empty strings, which have different DDL meanings.
proc ::tpersist::_schemaNode {node kind path} {
    set predicate [dict get {object is_object array is_array string is_string number is_number boolean is_bool} $kind]
    if {![::tjson::$predicate $node]} { _fail SCHEMA "$path must be a JSON $kind" }
    switch -- $kind {
        object {
            set result {}
            foreach child [::tjson::get_child_items $node] {
                set key [_schemaText [::tjson::get_string $child]]
                if {[dict exists $result $key]} { _fail SCHEMA "duplicate field $path.$key" }
                dict set result $key $child
            }
            return $result
        }
        array { return [::tjson::get_child_items $node] }
        string { return [_schemaText [::tjson::to_simple $node]] }
        default { return [::tjson::to_simple $node] }
    }
}

# Validate required and allowed fields in a JSON object.
proc ::tpersist::_schemaFields {node allowed required path} {
    set object [_schemaNode $node object $path]
    dict for {key value} $object {
        if {$key ni $allowed} { _fail SCHEMA "unknown field $path.$key" }
    }
    foreach key $required {
        if {![dict exists $object $key]} { _fail SCHEMA "missing field $path.$key" }
    }
    return $object
}

# Read an array of column names.
proc ::tpersist::_schemaNames {node path} {
    set result {}
    foreach value [_schemaNode $node array $path] {
        lappend result [_schemaNode $value string $path]
    }
    return $result
}

# Read a plain or schema-qualified table reference.
proc ::tpersist::_schemaTableRef {node path} {
    if {[::tjson::is_string $node]} { return [db_table [_schemaNode $node string $path]] }
    set ref [_schemaFields $node {name schema} name $path]
    set args {}
    if {[dict exists $ref schema]} { lappend args -schema [_schemaNode [dict get $ref schema] string $path.schema] }
    return [db_table [_schemaNode [dict get $ref name] string $path.name] {*}$args]
}

# Convert a JSON literal to a typed SQL default.
proc ::tpersist::_schemaDefault {node type path} {
    if {[::tjson::is_null $node]} { return [db_null] }
    switch -- $type {
        integer - bigint - real - double {
            if {[::tjson::is_number $node]} {
                set value [::tjson::to_simple $node]
                if {$type in {integer bigint}} {
                    # cJSON stores numbers as doubles. Reject values that cannot
                    # safely round-trip; exact large defaults use JSON strings.
                    if {![string is double -strict $value] || abs($value) > 9007199254740991 || $value != floor($value)} {
                        _fail SCHEMA "$path requires an exact integer; use a numeric string for large values"
                    }
                    set value [format %.0f $value]
                }
            } elseif {[::tjson::is_string $node]} {
                set value [::tjson::to_simple $node]
            } else { _fail SCHEMA "$path requires a number or numeric string" }
        }
        decimal {
            # Never silently round DECIMAL defaults through cJSON's double.
            set value [_schemaNode $node string $path]
        }
        boolean { set value [_schemaNode $node boolean $path] }
        text - varchar - date - timestamp {
            set value [_schemaNode $node string $path]
            if {$type eq "varchar"} { set type text }
        }
        default { _fail SCHEMA "$path does not support a $type default" }
    }
    set default [db_value $value -type $type]
    _defaultSql $default sqlite
    return $default
}

# Parse with tjson and release the document after validation.
proc ::tpersist::_schemaDocument {text} {
    package require tjson 1.0.27
    if {[catch {::tjson::parse $text} root]} { _fail JSON $root }
    try { return [_schemaFromNode $root] } finally { ::tjson::destroy $root }
}

# Convert version 1 JSON into table and index definitions.
proc ::tpersist::_schemaFromNode {root} {
    set root [_schemaFields $root {version tables} {version tables} schema]
    if {[_schemaNode [dict get $root version] number schema.version] ne "1"} {
        _fail SCHEMA "unsupported schema format version; expected 1"
    }
    set tables {}; set indexes {}; set seenTables {}; set seenIndexes {}
    foreach tableNode [_schemaNode [dict get $root tables] array schema.tables] {
        set table [_schemaFields $tableNode {name schema columns primary_key unique foreign_keys indexes} {name columns} table]
        set name [_schemaNode [dict get $table name] string table.name]
        set path "table($name)"
        set args {}; set schema {}
        if {[dict exists $table schema]} {
            set schema [_schemaNode [dict get $table schema] string $path.schema]
            lappend args -schema $schema
        }
        set key [list $schema $name]
        if {[dict exists $seenTables $key]} { _fail SCHEMA "duplicate table: $name" }
        dict set seenTables $key 1
        set columns {}
        dict for {column specNode} [_schemaNode [dict get $table columns] object $path.columns] {
            set cp "$path.columns.$column"
            set spec [_schemaFields $specNode {type length precision scale primary_key not_null unique auto_increment default} type $cp]
            set type [_schemaNode [dict get $spec type] string $cp.type]
            set converted [dict create type $type]
            dict for {field node} $spec {
                switch -- $field {
                    type { continue }
                    primary_key - not_null - unique - auto_increment {
                        set value [_schemaNode $node boolean $cp.$field]
                    }
                    length - precision - scale {
                        set value [_schemaNode $node number $cp.$field]
                        if {![regexp {^(0|[1-9][0-9]*)$} $value]} { _fail SCHEMA "$cp.$field requires a nonnegative integer" }
                    }
                    default { set value [_schemaDefault $node $type $cp.default] }
                }
                dict set converted $field $value
            }
            dict set columns $column $converted
        }
        if {[dict exists $table primary_key]} {
            lappend args -primary_key [_schemaNames [dict get $table primary_key] $path.primary_key]
        }
        if {[dict exists $table unique]} {
            set unique {}
            foreach names [_schemaNode [dict get $table unique] array $path.unique] {
                lappend unique [_schemaNames $names $path.unique]
            }
            lappend args -unique $unique
        }
        if {[dict exists $table foreign_keys]} {
            set foreignKeys {}
            foreach fkNode [_schemaNode [dict get $table foreign_keys] array $path.foreign_keys] {
                set fk [_schemaFields $fkNode {columns table referenced_columns on_delete on_update} {columns table referenced_columns} $path.foreign_keys]
                set converted {}
                dict for {field node} $fk {
                    switch -- $field {
                        columns - referenced_columns { set value [_schemaNames $node $path.foreign_keys.$field] }
                        table { set value [_schemaTableRef $node $path.foreign_keys.table] }
                        default { set value [_schemaNode $node string $path.foreign_keys.$field] }
                    }
                    dict set converted $field $value
                }
                lappend foreignKeys $converted
            }
            lappend args -foreign_keys $foreignKeys
        }
        set definition [db_define_table $name $columns {*}$args]
        lappend tables $definition
        if {![dict exists $table indexes]} { continue }
        foreach indexNode [_schemaNode [dict get $table indexes] array $path.indexes] {
            set index [_schemaFields $indexNode {name columns unique descending} {name columns} $path.indexes]
            set indexName [_schemaNode [dict get $index name] string $path.indexes.name]
            # Require schema-wide unique index names for portability to SQLite/PG.
            set key [list $schema $indexName]
            if {[dict exists $seenIndexes $key]} { _fail SCHEMA "duplicate index: $indexName" }
            dict set seenIndexes $key 1
            set names [_schemaNames [dict get $index columns] $path.indexes.columns]
            _columnList $names $columns sqlite
            set unique 0; set descending {}
            if {[dict exists $index unique]} { set unique [_schemaNode [dict get $index unique] boolean $path.indexes.unique] }
            if {[dict exists $index descending]} { set descending [_schemaNames [dict get $index descending] $path.indexes.descending] }
            set ref [_tableParts $definition]
            _createIndexSql $indexName $ref $names sqlite -unique $unique -descending $descending
            lappend indexes [dict create name $indexName table $ref columns $names unique $unique descending $descending]
        }
    }
    return [dict create version 1 tables $tables indexes $indexes]
}

# Reading does no database work; callers may inspect the definitions or pass
# individual tables to db_schema_sql before applying the file.
proc ::tpersist::db_read_schema {filename} {
    set channel [open $filename r]
    try {
        fconfigure $channel -encoding utf-8 -translation auto
        set text [read $channel]
    } finally { close $channel }
    return [_schemaDocument $text]
}

# Check MySQL index metadata without starting a transaction.
proc ::tpersist::_schemaMysqlIndexExists {handle index} {
    set parts [dict get $index table]
    set params [dict create table_name [dict get $parts name] index_name [dict get $index name]]
    set schema {DATABASE()}
    if {[dict exists $parts schema]} {
        set schema :schema_name
        dict set params schema_name [dict get $parts schema]
    }
    # Use _raw, not db_execute: an autobegin read must not start a transaction
    # immediately before MySQL DDL. Bind names as data in the catalog query.
    set rows [_raw $handle "SELECT 1 AS present FROM information_schema.statistics WHERE table_schema = $schema AND table_name = :table_name AND index_name = :index_name LIMIT 1" $params]
    return [expr {[llength $rows] != 0}]
}

# Read columns in the table's creation schema without triggering autobegin.
proc ::tpersist::_schemaTableColumns {handle definition dialect} {
    set table [_tableParts $definition]
    set params [dict create table_name [dict get $table name]]
    switch -- $dialect {
        sqlite {
            set schema main
            if {[dict exists $table schema]} { set schema [dict get $table schema] }
            dict set table schema $schema
            dict set params schema_name $schema
            set sql {SELECT name FROM pragma_table_xinfo(:table_name, :schema_name)}
        }
        postgresql {
            set schema {current_schema()}
            if {[dict exists $table schema]} {
                set schema :schema_name
                dict set params schema_name [dict get $table schema]
            }
            # A left join also recognizes PostgreSQL tables with no columns.
            set sql "SELECT a.attname AS name, n.nspname AS schema_name FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace LEFT JOIN pg_catalog.pg_attribute AS a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped WHERE n.nspname = $schema AND c.relname = :table_name"
        }
        mysql {
            set schema {DATABASE()}
            if {[dict exists $table schema]} {
                set schema :schema_name
                dict set params schema_name [dict get $table schema]
            }
            set sql "SELECT column_name AS name, table_schema AS schema_name FROM information_schema.columns WHERE table_schema = $schema AND table_name = :table_name"
        }
    }
    set rows [_raw $handle $sql $params]
    if {![llength $rows]} { return {} }
    if {$dialect ne "sqlite"} { dict set table schema [dict get [lindex $rows 0] schema_name] }
    set columns {}
    foreach row $rows {
        if {[dict exists $row name]} { lappend columns [dict get $row name] }
    }
    return [dict create table $table columns $columns]
}

# Respect PostgreSQL case sensitivity and SQLite/MySQL ASCII name folding.
proc ::tpersist::_schemaColumnKey {name dialect} {
    if {$dialect eq "postgresql"} { return $name }
    return [string map {A a B b C c D d E e F f G g H h I i J j K k L l M m N n O o P p Q q R r S s T t U u V v W w X x Y y Z z} $name]
}

# Plan portable column additions; constraints on existing tables need migrations.
proc ::tpersist::_schemaAdditions {handle definitions dialect} {
    set statements {}
    foreach definition $definitions {
        set existing [_schemaTableColumns $handle $definition $dialect]
        if {$existing eq {}} { continue }
        set columns {}
        foreach name [dict get $existing columns] { dict set columns [_schemaColumnKey $name $dialect] 1 }
        set constrained [_validateTable $definition]
        if {[dict exists $definition unique]} {
            foreach names [dict get $definition unique] { lappend constrained {*}$names }
        }
        if {[dict exists $definition foreign_keys]} {
            foreach fk [dict get $definition foreign_keys] { lappend constrained {*}[dict get $fk columns] }
        }
        dict for {name spec} [dict get $definition columns] {
            if {[dict exists $columns [_schemaColumnKey $name $dialect]]} { continue }
            if {$name in $constrained || [_flag $spec unique] || [_flag $spec auto_increment]} {
                _fail UNSUPPORTED "adding constrained column $name requires a migration; use sql/migrations/"
            }
            if {[_flag $spec not_null] && (![dict exists $spec default] || [dict get $spec default node] eq "null")} {
                _fail UNSUPPORTED "adding NOT NULL column $name requires a non-null default or a migration"
            }
            lappend statements "ALTER TABLE [_tableName [dict get $existing table] $dialect] ADD COLUMN [_columnSql $name $spec $dialect]"
        }
    }
    return $statements
}

# Create missing objects, optionally adding missing columns to existing tables.
proc ::tpersist::db_apply_schema {handle filename args} {
    set additive [_ddlOption $args -additive]
    set c [_connection $handle]
    set dialect [dict get $c dialect]
    set document [db_read_schema $filename]
    if {$dialect eq "mysql" && [dict get $c transaction]} {
        _fail TRANSACTION "MySQL schema commands require no active transaction because DDL can commit implicitly"
    }
    # Validate every statement for this dialect before issuing any DDL, even
    # when the corresponding table/index already exists.
    foreach definition [dict get $document tables] { _createTableSql $definition $dialect 1 }
    foreach index [dict get $document indexes] {
        _createIndexSql [dict get $index name] [dict get $index table] [dict get $index columns] $dialect \
            -unique [dict get $index unique] -descending [dict get $index descending]
    }
    set additions {}
    if {$additive} { set additions [_schemaAdditions $handle [dict get $document tables] $dialect] }
    foreach definition [dict get $document tables] { db_create_table $handle $definition -if_not_exists 1 }
    foreach sql $additions { _ddl $handle $sql }
    foreach index [dict get $document indexes] {
        if {$dialect eq "mysql" && [_schemaMysqlIndexExists $handle $index]} { continue }
        db_create_index $handle [dict get $index name] [dict get $index table] [dict get $index columns] \
            -unique [dict get $index unique] -descending [dict get $index descending] \
            -if_not_exists [expr {$dialect ne "mysql"}]
    }
    return
}
