# Copyright Jerily LTD. All Rights Reserved.
# SPDX-License-Identifier: MIT.

proc ::tpersist::_jsonlOptions {path args} {
    if {[llength $args] % 2} {_fail ARGS "JSONL options must be name/value pairs"}
    set options [dict create schema {} gzip [string match *.gz $path] deadline {} max_bytes {}]
    foreach {key value} $args {
        switch -- $key {
            -tables {dict set options tables $value}
            -schema {dict set options schema $value}
            -gzip {
                if {![string is boolean -strict $value]} {_fail ARGS "-gzip requires a boolean"}
                dict set options gzip [expr {!!$value}]
            }
            -deadline - -max_bytes {
                if {![string is entier -strict $value] || $value < 0} {_fail ARGS "$key requires a nonnegative integer"}
                dict set options [string range $key 1 end] $value
            }
            default {_fail ARGS "unknown JSONL option: $key"}
        }
    }
    return $options
}

proc ::tpersist::_jsonlCheck {options {path {}}} {
    if {[dict get $options deadline] ne {} && [clock milliseconds] >= [dict get $options deadline]} {_fail LIMIT "JSONL operation deadline exceeded"}
    if {$path ne {} && [dict get $options max_bytes] ne {} && [file size $path] > [dict get $options max_bytes]} {_fail LIMIT "JSONL file size limit exceeded"}
}

# Handle JSON null explicitly: tjson's typed null spelling differs between
# releases. Its scalar encoder still supplies string escaping and booleans.
proc ::tpersist::_jsonlEncode {typed} {
    lassign $typed type value
    switch -- $type {
        NULL {return null}
        M {
            set parts {}
            dict for {key item} $value {lappend parts "[::tjson::typed_to_json [list S $key]]:[_jsonlEncode $item]"}
            return \{[join $parts ,]\}
        }
        L {return \[[join [lmap item $value {_jsonlEncode $item}] ,]\]}
        default {return [::tjson::typed_to_json $typed]}
    }
}

proc ::tpersist::_jsonlWrite {channel record} {puts $channel [_jsonlEncode [list M $record]]}

# Tcl's gunzip channel can report EOF for a truncated trailer. Verify the
# inflater reached its own end marker before using the archive. Read bounded
# chunks and discard output; this pass never buffers the whole backup.
proc ::tpersist::_jsonlValidateGzip {channel options} {
    set stream [zlib stream gunzip]
    try {
        while {![eof $channel]} {
            _jsonlCheck $options
            set chunk [read $channel 4096]
            if {$chunk eq {}} break
            $stream put $chunk
            while {[$stream get 65536] ne {}} {}
        }
        if {![$stream eof]} {_fail JSON "incomplete gzip stream"}
    } finally {$stream close}
    seek $channel 0
}

proc ::tpersist::_jsonlReady {handle} {
    package require tjson 1.0.27
    if {[dict get [_connection $handle] transaction]} {_fail TRANSACTION "JSONL export/import requires no active transaction"}
}

# Export an atomic file from one consistent snapshot. Failed exports never
# replace a previous backup. PostgreSQL cursors avoid buffering entire tables.
proc ::tpersist::db_export_jsonl {handle path args} {
    _jsonlReady $handle
    set options [_jsonlOptions $path {*}$args]
    set schema [_backupSchema $handle [dict get $options schema]]
    set dialect [db_dialect $handle]
    set channel {}; set temporary {}
    try {
        _jsonlCheck $options
        db_begin $handle
        if {$dialect eq "postgresql"} {_raw $handle {SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY}}
        set tables [db_tables $handle -schema $schema]
        if {[dict exists $options tables]} {set tables [_backupNames $tables [dict get $options tables]]}
        set snapshots {}; set byName {}
        foreach name $tables {
            _jsonlCheck $options
            set snapshot [_backupTable $handle $schema $name]
            dict set byName $name $snapshot
            lappend snapshots $snapshot
        }
        set schemaJson [_jsonlEncode [list M [dict create version {N 1} tables [list L $snapshots]]]]
        set definitions [_backupOrder [dict get [_schemaDocument $schemaJson] tables]]
        set snapshots [lmap definition $definitions {dict get $byName [dict get $definition name]}]
        set channel [file tempfile temporary [file join [file dirname $path] .tpersist-jsonl-]]
        if {[dict get $options gzip]} {zlib push gzip $channel}
        fconfigure $channel -encoding utf-8 -translation lf
        _jsonlWrite $channel [dict create format {S tpersist} version {N 1} dialect [list S $dialect] created_at [list N [clock seconds]] schema [list M [dict create version {N 1} tables [list L $snapshots]]]]
        set counts {}
        foreach definition $definitions {
            set name [dict get $definition name]
            set columns [dict get $definition columns]
            set table [db_table $name -schema $schema]
            dict set counts $name 0
            set sql "SELECT * FROM [_tableName $table $dialect]"
            if {$dialect eq "postgresql"} {
                _raw $handle "DECLARE tpersist_jsonl NO SCROLL CURSOR FOR $sql"
                try {
                    while {1} {
                        _jsonlCheck $options $temporary
                        set rows [_raw $handle {FETCH FORWARD 256 FROM tpersist_jsonl}]
                        if {![llength $rows]} break
                        foreach row $rows {
                            _jsonlRow $channel $name $columns $row
                            dict incr counts $name
                        }
                        flush $channel
                    }
                } finally {_raw $handle {CLOSE tpersist_jsonl}}
            } else {
                db_foreach_row $handle row [db_select $table] {
                    _jsonlRow $channel $name $columns $row
                    dict incr counts $name
                    if {[dict get $counts $name] % 256 == 0} {flush $channel; _jsonlCheck $options $temporary}
                }
            }
        }
        set typedCounts {}
        dict for {name count} $counts {dict set typedCounts $name [list N $count]}
        _jsonlWrite $channel [dict create complete {BOOL 1} counts [list M $typedCounts]]
        close $channel
        set channel {}
        _jsonlCheck $options $temporary
        db_commit $handle
        file rename -force $temporary $path
        set temporary {}
        return $counts
    } on error {message opts} {
        catch {db_rollback $handle}
        return -options $opts $message
    } finally {
        if {$channel ne {}} {catch {close $channel}}
        if {$temporary ne {}} {file delete -force $temporary}
    }
}

# Numbers are strings to preserve all 64-bit integers and decimal digits through
# JSON readers. NULL is explicit; binary columns are base64, including empty blobs.
proc ::tpersist::_jsonlRow {channel table columns row} {
    set values {}
    dict for {name spec} $columns {
        if {![dict exists $row $name]} {dict set values $name {NULL {}}; continue}
        set value [dict get $row $name]
        if {[dict get $spec type] in {binary blob}} {set value [binary encode base64 -maxlen 0 $value]}
        if {[dict get $spec type] ni {binary blob} && [string first \x00 $value] >= 0} {
            dict set values $name [list M [dict create utf8 [list S [binary encode base64 -maxlen 0 [encoding convertto utf-8 $value]]]]]
        } else {dict set values $name [list S $value]}
    }
    _jsonlWrite $channel [dict create table [list S $table] values [list M $values]]
}

proc ::tpersist::_jsonlHeader {root} {
    set fields [_schemaFields $root {format version dialect created_at schema} {format version dialect schema} backup]
    if {[_schemaNode [dict get $fields format] string backup.format] ne "tpersist" ||
        [_schemaNode [dict get $fields version] number backup.version] ne "1"} {_fail JSON "unsupported JSONL backup format"}
    set schema [_schemaFromNode [dict get $fields schema]]
    # Archives name tables within a schema, never destination schemas or SQL.
    foreach definition [dict get $schema tables] {
        if {[dict exists $definition schema]} {_fail JSON "backup tables must be unqualified"}
        if {[dict exists $definition foreign_keys]} {
            foreach fk [dict get $definition foreign_keys] {
                if {[dict exists [_tableParts [dict get $fk table]] schema]} {_fail JSON "backup foreign keys must be unqualified"}
            }
        }
    }
    return $schema
}

# Create missing tables from the archived schema, then import into empty tables
# in a single transaction. SQLite and PostgreSQL roll back DDL as well as rows.
proc ::tpersist::db_import_jsonl {handle path args} {
    _jsonlReady $handle
    set options [_jsonlOptions $path {*}$args]
    set schema [_backupSchema $handle [dict get $options schema]]
    set dialect [db_dialect $handle]
    set channel {}; set statements {}
    try {
        _jsonlCheck $options $path
        set channel [open $path rb]
        if {[dict get $options gzip]} {
            _jsonlValidateGzip $channel $options
            zlib push gunzip $channel
        }
        fconfigure $channel -encoding utf-8 -translation lf
        if {[gets $channel line] < 0} {_fail JSON "empty JSONL backup"}
        set root [::tjson::parse $line]
        try {set document [_jsonlHeader $root]} finally {::tjson::destroy $root}
        set definitions [_backupOrder [dict get $document tables]]
        set allNames [lmap definition $definitions {dict get $definition name}]
        set selected $allNames
        if {[dict exists $options tables]} {set selected [_backupNames $allNames [dict get $options tables]]}
        db_begin $handle
        set available [db_tables $handle -schema $schema]
        set existingIndexes {}
        set byName {}; set counts {}; set imported {}; set targets {}
        foreach definition $definitions {
            set name [dict get $definition name]
            if {$dialect eq "sqlite" && [string match -nocase sqlite_* $name]} {_fail JSON "system tables cannot be imported"}
            dict set byName $name $definition
            dict set counts $name 0
            if {$name ni $selected} continue
            dict set imported $name 0
            set target $definition
            dict set target schema $schema
            if {[dict exists $target foreign_keys]} {
                set fks {}
                foreach fk [dict get $target foreign_keys] {
                    # SQLite REFERENCES always resolves within the table's schema.
                    if {$dialect eq "postgresql"} {dict set fk table [db_table [dict get [_tableParts [dict get $fk table]] name] -schema $schema]}
                    lappend fks $fk
                }
                dict set target foreign_keys $fks
            }
            dict set targets $name $target
            if {$name ni $available} {
                db_create_table $handle $target
            } else {
                if {$dialect eq "postgresql"} {_raw $handle "LOCK TABLE [_tableName $target $dialect] IN ACCESS EXCLUSIVE MODE"}
                set live [_backupTable $handle $schema $name]
                set liveDoc [_schemaDocument [_jsonlEncode [list M [dict create version {N 1} tables [list L [list $live]]]]]]
                if {[db_schema_sql [lindex [dict get $liveDoc tables] 0] -dialect $dialect] ne [db_schema_sql $definition -dialect $dialect]} {_fail SCHEMA "existing table does not match archived schema: $name"}
                foreach index [dict get $liveDoc indexes] {
                    if {$index ni [dict get $document indexes]} {_fail SCHEMA "existing index does not match archived schema: [dict get $index name]"}
                    lappend existingIndexes [dict get $index name]
                }
            }
            if {[llength [_raw $handle "SELECT 1 FROM [_tableName $target $dialect] LIMIT 1"]]} {_fail VALIDATION "import requires empty tables: $name"}
            set names {}; set binds {}; set i 0
            dict for {column spec} [dict get $definition columns] {
                lappend names [_quote $column $dialect]
                lappend binds :p[incr i]
            }
            set db [dict get [_connection $handle] command]
            set statement [$db prepare "INSERT INTO [_tableName $target $dialect] ([join $names ,]) VALUES ([join $binds ,])"]
            dict set statements $name $statement
            set i 0
            dict for {column spec} [dict get $definition columns] {
                incr i
                if {[dict get $spec type] in {binary blob}} {$statement paramtype p$i varbinary}
            }
        }
        set complete 0
        while {[gets $channel line] >= 0} {
            _jsonlCheck $options
            set root [::tjson::parse $line]
            try {
                set fields [_schemaNode $root object record]
                if {[dict exists $fields complete]} {
                    _schemaFields $root {complete counts} {complete counts} footer
                    if {![_schemaNode [dict get $fields complete] boolean footer.complete]} {_fail JSON "incomplete JSONL backup"}
                    set actual [_schemaNode [dict get $fields counts] object footer.counts]
                    if {[lsort [dict keys $actual]] ne [lsort $allNames]} {_fail JSON "invalid JSONL footer tables"}
                    dict for {name node} $actual {
                        if {[_schemaNode $node number footer.count] ne [dict get $counts $name]} {_fail JSON "JSONL row count mismatch: $name"}
                    }
                    if {[gets $channel line] >= 0} {_fail JSON "records after JSONL footer"}
                    set complete 1
                    break
                }
                _schemaFields $root {table values} {table values} row
                set name [_schemaNode [dict get $fields table] string row.table]
                if {![dict exists $byName $name]} {_fail JSON "unknown JSONL table: $name"}
                set columns [dict get $byName $name columns]
                set values [_schemaNode [dict get $fields values] object row.values]
                if {[lsort [dict keys $values]] ne [lsort [dict keys $columns]]} {_fail JSON "JSONL columns do not match archived schema: $name"}
                set params {}; set i 0
                dict for {column spec} $columns {
                    incr i
                    set node [dict get $values $column]
                    if {[::tjson::is_null $node]} continue
                    if {[::tjson::is_object $node] && [dict get $spec type] ni {binary blob}} {
                        set encoded [_schemaFields $node {utf8} {utf8} row.value]
                        set value [_schemaNode [dict get $encoded utf8] string row.value.utf8]
                        set value [encoding convertfrom utf-8 [binary decode base64 -strict $value]]
                    } else {set value [_schemaNode $node string row.value]}
                    if {[dict get $spec type] in {binary blob}} {
                        set decoded [binary decode base64 -strict $value]
                        if {[binary encode base64 -maxlen 0 $decoded] ne $value} {_fail JSON "noncanonical base64 in JSONL row"}
                        set value $decoded
                    }
                    dict set params p$i $value
                }
                if {$name in $selected} {
                    set rs [[dict get $statements $name] execute $params]
                    $rs close
                    dict incr imported $name
                }
                dict incr counts $name
            } finally {::tjson::destroy $root}
        }
        if {!$complete} {_fail JSON "missing JSONL completion footer"}
        # Closing the gzip reader must succeed before committing anything.
        close $channel
        set channel {}
        foreach statement [dict values $statements] {$statement close}
        set statements {}
        foreach index [dict get $document indexes] {
            set name [dict get [_tableParts [dict get $index table]] name]
            if {$name ni $selected || [dict get $index name] in $existingIndexes} continue
            db_create_index $handle [dict get $index name] [dict get $targets $name] [dict get $index columns] -unique [dict get $index unique] -descending [dict get $index descending]
        }
        if {$dialect eq "postgresql"} {
            dict for {name target} $targets {
                dict for {column spec} [dict get $target columns] {
                    if {![_flag $spec auto_increment]} continue
                    # Transactional ALTER SEQUENCE avoids setval's non-rollback
                    # side effects on a pre-existing empty destination table.
                    set relation [_tableName $target $dialect]
                    set sequence [dict get [lindex [_raw $handle {SELECT pg_get_serial_sequence(:relation, :column) AS name} [dict create relation $relation column $column]] 0] name]
                    set next [dict get [lindex [_raw $handle "SELECT COALESCE(MAX([_quote $column $dialect]),0) + 1 AS n FROM $relation"] 0] n]
                    if {![string is entier -strict $next] || $next < 1} {_fail JSON "invalid identity sequence value"}
                    # pg_get_serial_sequence returns a server-quoted qualified name.
                    _raw $handle "ALTER SEQUENCE $sequence RESTART WITH $next"
                }
            }
        }
        _jsonlCheck $options
        db_commit $handle
        return $imported
    } on error {message opts} {
        catch {db_rollback $handle}
        return -options $opts $message
    } finally {
        foreach statement [dict values $statements] {catch {$statement close}}
        if {$channel ne {}} {catch {close $channel}}
    }
}
