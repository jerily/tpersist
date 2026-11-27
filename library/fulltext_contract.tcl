# Copyright Jerily LTD. All Rights Reserved.
# SPDX-License-Identifier: MIT.

# Query compilation and DDL must derive exactly the same names offline, including
# when prefixes, long names or multibyte identifiers are used. NUL cannot occur
# in an SQL identifier and separates the two components without ambiguity.
proc ::tpersist::_ftsName {physicalTable virtualName role} {
    if {$role eq "column"} {
        set key $virtualName
    } else {
        set key "$physicalTable\x00$virtualName"
    }
    binary scan [encoding convertto utf-8 $key] cu* bytes
    set hash 14695981039346656037
    foreach byte $bytes {
        set hash [expr {(($hash ^ $byte) * 1099511628211) & 0xffffffffffffffff}]
    }
    return [format "__tpfts_%s_%016llx" $role $hash]
}

# Schema files can be applied to tables created outside tpersist. Check their
# actual keys and column types before installing or rebuilding an index.
proc ::tpersist::_ftsValidateLive {handle table spec} {
    set dialect [db_dialect $handle]
    set schema [_ftsSchema $handle $table]
    set base [dict get [_tableParts $table] name]
    set id [dict get $spec document_id]
    set params [dict create schema $schema base $base]
    switch -- $dialect {
        sqlite {
            set metadata [_raw $handle {SELECT type, wr FROM pragma_table_list WHERE schema = :schema AND name = :base COLLATE NOCASE} $params]
            if {![llength $metadata] || [dict get [lindex $metadata 0] type] ne "table" || [dict get [lindex $metadata 0] wr]} {
                _fail SCHEMA "SQLite full-text search requires a rowid table: $base"
            }
            set encoding [lindex [_raw $handle "PRAGMA [_quote $schema sqlite].encoding"] 0]
            if {[dict get $encoding encoding] ne "UTF-8"} {_fail SCHEMA "full-text search requires a UTF-8 database"}
            set rows [_raw $handle {SELECT name, lower(type) AS coltype, "notnull" AS nn, pk
                FROM pragma_table_xinfo(:base, :schema) WHERE hidden = 0} $params]
            set keys [_raw $handle {SELECT max(x.name) AS name FROM pragma_index_list(:base, :schema) i
                JOIN pragma_index_info(i.name, :schema) x
                WHERE i."unique" = 1 AND i.partial = 0 GROUP BY i.name HAVING count(*) = 1} $params]
            set pkIndex [_raw $handle {SELECT 1 FROM pragma_index_list(:base, :schema) WHERE origin = 'pk'} $params]
            set primary {}
            foreach row $rows {
                if {[string equal -nocase [dict get $row name] _rowid_]} {_fail SCHEMA "$base shadows SQLite _rowid_"}
                if {[dict get $row pk]} {lappend primary [dict get $row name]}
            }
            # A single INTEGER PRIMARY KEY aliases rowid and has no separate
            # index. Non-INTEGER SQLite primary keys can admit NULL.
            if {[llength $primary] == 1} {lappend keys [dict create name [lindex $primary 0]]}
        }
        postgresql {
            set rows [_raw $handle {SELECT a.attname AS name, t.typname AS coltype, a.attnotnull AS nn,
                    current_setting('server_encoding') AS charset
                FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
                JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = :schema AND c.relname = :base AND a.attnum > 0 AND NOT a.attisdropped} $params]
            set keys [_raw $handle {SELECT a.attname AS name FROM pg_catalog.pg_index i
                JOIN pg_catalog.pg_class c ON c.oid = i.indrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
                WHERE n.nspname = :schema AND c.relname = :base AND i.indisunique AND i.indisvalid AND i.indisready
                    AND i.indnkeyatts = 1 AND i.indpred IS NULL AND i.indexprs IS NULL} $params]
        }
        mysql {
            set rows [_raw $handle {SELECT c.column_name AS name, c.data_type AS coltype, (c.is_nullable = 'NO') AS nn,
                    c.character_set_name AS charset, t.engine AS engine
                FROM information_schema.columns c JOIN information_schema.tables t USING (table_schema,table_name)
                WHERE c.table_schema = :schema AND c.table_name = :base} $params]
            set keys [_raw $handle {SELECT max(column_name) AS name FROM information_schema.statistics
                WHERE table_schema = :schema AND table_name = :base AND non_unique = 0
                GROUP BY index_name HAVING count(*) = 1 AND count(sub_part) = 0} $params]
        }
    }
    set columns {}
    foreach row $rows {dict set columns [_schemaColumnKey [dict get $row name] $dialect] $row}
    set unique {}
    foreach key $keys {
        if {[dict exists $key name]} {dict set unique [_schemaColumnKey [dict get $key name] $dialect] 1}
    }
    set idKey [_schemaColumnKey $id $dialect]
    if {![dict exists $unique $idKey] || ![dict exists $columns $idKey]} {
        _fail SCHEMA "$base.$id must have a single-column unique key"
    }
    set row [dict get $columns $idKey]
    set pkAlias [expr {$dialect eq "sqlite" && ![llength $pkIndex] && [dict get $row coltype] eq "integer" && $primary eq [list [dict get $row name]]}]
    if {[dict get $row coltype] ni {integer bigint int int4 int8} || (![dict get $row nn] && !$pkAlias)} {
        _fail SCHEMA "$base.$id must be a non-null integer document ID"
    }
    if {$dialect eq "postgresql" && [dict get $row charset] ne "UTF8"} {_fail SCHEMA "full-text search requires a UTF-8 database"}
    if {$dialect eq "mysql" && [dict get $row engine] ne "InnoDB"} {_fail SCHEMA "MySQL full-text search requires InnoDB"}
    foreach name [dict get $spec columns] {
        set key [_schemaColumnKey $name $dialect]
        if {![dict exists $columns $key]} {_fail SCHEMA "missing full-text source $base.$name"}
        set row [dict get $columns $key]
        if {![regexp {^(text|varchar(\([0-9]+\))?)$} [dict get $row coltype]]} {_fail SCHEMA "full-text source $base.$name must be text or varchar"}
        if {$dialect eq "mysql" && [dict get $row charset] ne "utf8mb4"} {_fail SCHEMA "full-text source $base.$name must use utf8mb4"}
    }
}
