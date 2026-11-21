# Copyright Jerily LTD. All Rights Reserved.
# SPDX-License-Identifier: MIT.

# JSONL backups cover ordinary application tables in one database schema.
proc ::tpersist::_backupSchema {handle schema} {
    switch -- [db_dialect $handle] {
        sqlite {
            if {$schema eq {}} {set schema main}
            if {![llength [_raw $handle {SELECT 1 FROM pragma_database_list WHERE name = :schema} [dict create schema $schema]]]} {_fail VALIDATION "unknown database schema: $schema"}
        }
        postgresql {
            if {[dict get [lindex [_raw $handle {SELECT current_setting('server_version_num')::integer AS version}] 0] version] < 150000} {_fail UNSUPPORTED "JSONL schema backups require PostgreSQL 15 or newer"}
            if {$schema eq {}} {set schema [dict get [lindex [_raw $handle {SELECT current_schema() AS name}] 0] name]}
            if {$schema eq "information_schema" || [string match pg_* $schema]} {
                _fail VALIDATION "system schemas cannot be exported or imported"
            }
            if {![llength [_raw $handle {SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = :schema} [dict create schema $schema]]]} {_fail VALIDATION "unknown database schema: $schema"}
        }
        default {_fail UNSUPPORTED "JSONL schema backups currently support SQLite and PostgreSQL"}
    }
    _quote $schema [db_dialect $handle]
    return $schema
}

proc ::tpersist::db_tables {handle args} {
    set schema {}
    if {[llength $args]} {
        if {[llength $args] != 2 || [lindex $args 0] ne "-schema"} {_fail ARGS "expected: db_tables connection ?-schema name?"}
        set schema [lindex $args 1]
    }
    set schema [_backupSchema $handle $schema]
    if {[db_dialect $handle] eq "sqlite"} {
        set rows [_raw $handle {SELECT name FROM pragma_table_list WHERE schema = :schema AND type IN ('table','virtual') AND name NOT LIKE 'sqlite\_%' ESCAPE '\' ORDER BY name} [dict create schema $schema]]
    } else {
        set rows [_raw $handle {SELECT c.relname AS name FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = :schema AND c.relkind IN ('r','p') AND NOT c.relispartition
            AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
            ORDER BY c.relname} [dict create schema $schema]]
    }
    return [lmap row $rows {dict get $row name}]
}

proc ::tpersist::_backupNames {available requested} {
    if {[llength $requested] != [llength [lsort -unique $requested]]} {_fail ARGS "duplicate table selection"}
    foreach table $requested {
        if {$table ni $available} {_fail VALIDATION "unknown application table: $table"}
    }
    return $requested
}

proc ::tpersist::_jsonStrings {values} {return [list L [lmap v $values {list S $v}]]}

# Catalog types are deliberately limited to the portable schema vocabulary.
# Fail explicitly instead of producing a backup with silently weakened DDL.
proc ::tpersist::_backupType {native} {
    set native [string tolower [string trim $native]]
    set map {int integer int4 integer int8 bigint float8 double {double precision} double float4 real bool boolean bytea binary blob binary {timestamp without time zone} timestamp {character varying} text}
    if {[dict exists $map $native]} {set native [dict get $map $native]}
    if {[regexp {^(?:character varying|varchar)\(([0-9]+)\)$} $native -> length]} {
        return [dict create type {S varchar} length [list N $length]]
    }
    if {[regexp {^(?:numeric|decimal)\(([0-9]+),\s*([0-9]+)\)$} $native -> precision scale]} {
        return [dict create type {S decimal} precision [list N $precision] scale [list N $scale]]
    }
    if {$native eq "numeric"} {set native decimal}
    if {$native ni {integer bigint real double text binary boolean decimal date timestamp}} {
        _fail UNSUPPORTED "unsupported backup column type: $native"
    }
    return [dict create type [list S $native]]
}

proc ::tpersist::_backupDefault {value type dialect} {
    set value [string trim $value]
    # PostgreSQL renders literal defaults with a cast, e.g. ''::text.
    if {$dialect eq "postgresql"} {regsub {::[a-zA-Z][a-zA-Z0-9_ () ,]*$} $value {} value}
    if {[string equal -nocase $value NULL]} {return {N null}}
    if {[regexp {^'((?:[^']|'')*)'$} $value -> literal]} {
        return [list S [string map {'' '} $literal]]
    }
    if {$type eq "boolean" && [string tolower $value] in {true false 0 1}} {
        return [list BOOL [expr {[string tolower $value] in {true 1}}]]
    }
    if {$type in {integer bigint real double decimal} && [regexp {^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$} $value]} {
        return [list S $value]
    }
    _fail UNSUPPORTED "expression defaults cannot be represented by a portable JSON schema"
}

proc ::tpersist::_backupTable {handle schema name} {
    set dialect [db_dialect $handle]
    set params [dict create schema $schema name $name]
    set columns {}; set pk {}; set unique {}; set indexes {}; set foreign {}
    if {$dialect eq "sqlite"} {
        set tableSql [dict get [lindex [_raw $handle "SELECT sql FROM [_quote $schema sqlite].sqlite_schema WHERE type = 'table' AND name = :name" $params] 0] sql]
        # Ignore quoted identifiers and literals when looking for unsupported
        # SQL clauses (a column named "check" is an ordinary identifier).
        regsub -all {('(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\])} $tableSql {} syntax
        if {[regexp -nocase {\m(CHECK|COLLATE|GENERATED|DEFERRABLE|WITHOUT|STRICT|VIRTUAL|CONFLICT)\M} $syntax]} {
            _fail UNSUPPORTED "table $name uses SQLite DDL outside the portable schema format"
        }
        if {[llength [_raw $handle "SELECT 1 FROM [_quote $schema sqlite].sqlite_schema WHERE type = 'trigger' AND tbl_name = :name" $params]]} {
            _fail UNSUPPORTED "table $name has triggers"
        }
        foreach row [_raw $handle {SELECT * FROM pragma_table_xinfo(:name, :schema) ORDER BY cid} $params] {
            if {[dict get $row hidden]} {_fail UNSUPPORTED "generated columns are not supported in backups"}
            set column [dict get $row name]
            set spec [_backupType [dict get $row type]]
            if {[dict get $row notnull]} {dict set spec not_null {BOOL 1}}
            if {[dict get $row pk]} {dict set pk [dict get $row pk] $column}
            if {[dict exists $row dflt_value]} {
                dict set spec default [_backupDefault [dict get $row dflt_value] [lindex [dict get $spec type] 1] sqlite]
            }
            dict set columns $column [list M $spec]
        }
        set pk [lmap key [lsort -integer [dict keys $pk]] {dict get $pk $key}]
        if {[llength $pk] == 1 && [regexp -nocase {\mAUTOINCREMENT\M} $syntax]} {
            set column [lindex $pk 0]
            set spec [lindex [dict get $columns $column] 1]
            dict set spec auto_increment {BOOL 1}
            dict set spec primary_key {BOOL 1}
            dict set columns $column [list M $spec]
            set pk {}
        }
        foreach row [_raw $handle {SELECT * FROM pragma_index_list(:name, :schema) ORDER BY name} $params] {
            if {[dict get $row partial]} {_fail UNSUPPORTED "partial indexes cannot be represented by a portable JSON schema"}
            set names {}; set desc {}
            set ip [dict create schema $schema name [dict get $row name]]
            foreach part [_raw $handle {SELECT * FROM pragma_index_xinfo(:name, :schema) WHERE key = 1 ORDER BY seqno} $ip] {
                if {[dict get $part cid] < 0 || [dict get $part coll] ne "BINARY"} {_fail UNSUPPORTED "expression/collation indexes are not supported in backups"}
                lappend names [dict get $part name]
                if {[dict get $part desc]} {lappend desc [dict get $part name]}
            }
            if {[dict get $row origin] in {pk u} && [llength $desc]} {_fail UNSUPPORTED "descending constraint indexes are not supported in backups"}
            if {[dict get $row origin] eq "pk"} continue
            if {[dict get $row origin] eq "u"} {
                lappend unique [_jsonStrings $names]
            } else {
                lappend indexes [list M [dict create name [list S [dict get $row name]] columns [_jsonStrings $names] unique [list BOOL [dict get $row unique]] descending [_jsonStrings $desc]]]
            }
        }
        foreach row [_raw $handle {SELECT * FROM pragma_foreign_key_list(:name, :schema) ORDER BY id, seq} $params] {
            set id [dict get $row id]
            if {![dict exists $foreign $id]} {dict set foreign $id [dict create table [list S [dict get $row table]] columns {L {}} referenced_columns {L {}} on_delete [list S [string tolower [dict get $row on_delete]]] on_update [list S [string tolower [dict get $row on_update]]]]}
            foreach {field key} {columns from referenced_columns to} {
                if {![dict exists $row $key]} {_fail UNSUPPORTED "implicit foreign-key columns are not supported in backups"}
                set items [lindex [dict get $foreign $id $field] 1]
                lappend items [list S [dict get $row $key]]
                dict set foreign $id $field [list L $items]
            }
        }
    } else {
        set table [db_table $name -schema $schema]
        dict set params relation [_tableName $table postgresql]
        # This format cannot faithfully represent these features. Never silently
        # omit them from a backup advertised as sufficient for reconstruction.
        set unsupported [_raw $handle {SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid = :relation::regclass AND
            (c.relkind <> 'r' OR c.relrowsecurity OR c.relforcerowsecurity OR
             EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid = c.oid AND i.indnullsnotdistinct) OR
             EXISTS (SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhrelid = c.oid OR i.inhparent = c.oid) OR
             EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal) OR
             EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conrelid = c.oid AND (k.contype NOT IN ('p','u','f') OR k.condeferrable OR NOT k.convalidated OR (k.contype = 'f' AND (k.confmatchtype <> 's' OR k.confdelsetcols IS NOT NULL)))))} $params]
        if {[llength $unsupported]} {_fail UNSUPPORTED "table $name uses PostgreSQL DDL outside the portable schema format"}
        foreach row [_raw $handle {SELECT a.attname AS name, pg_catalog.format_type(a.atttypid,a.atttypmod) AS type,
            a.attnotnull AS not_null, a.attidentity AS identity, a.attgenerated AS generated,
            pg_catalog.pg_get_expr(d.adbin,d.adrelid) AS default_value,
            a.attcollation <> t.typcollation AS custom_collation
            FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = :relation::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum} $params] {
            if {[dict get $row generated] ne {} || [dict get $row custom_collation]} {_fail UNSUPPORTED "generated columns and custom collations are not supported in backups"}
            set column [dict get $row name]
            set spec [_backupType [dict get $row type]]
            if {[dict get $row not_null]} {dict set spec not_null {BOOL 1}}
            if {[dict get $row identity] ne {}} {
                if {[dict get $row identity] ne "d"} {_fail UNSUPPORTED "GENERATED ALWAYS identity is not supported in portable backups"}
                set sequenceParams [dict merge $params [dict create column $column]]
                if {[llength [_raw $handle {SELECT 1 FROM pg_catalog.pg_sequence s
                    WHERE s.seqrelid = pg_get_serial_sequence(:relation, :column)::regclass
                    AND (s.seqstart <> 1 OR s.seqincrement <> 1 OR s.seqmin <> 1 OR s.seqcache <> 1 OR s.seqcycle
                         OR s.seqmax <> CASE WHEN s.seqtypid = 'int4'::regtype THEN 2147483647 ELSE 9223372036854775807 END)} $sequenceParams]]} {_fail UNSUPPORTED "custom identity sequence settings are not supported in backups"}
                dict set spec auto_increment {BOOL 1}
                dict set spec primary_key {BOOL 1}
            } elseif {[dict exists $row default_value]} {
                dict set spec default [_backupDefault [dict get $row default_value] [lindex [dict get $spec type] 1] postgresql]
            }
            dict set columns $column [list M $spec]
        }
        set constraints [_raw $handle {SELECT k.oid, k.contype, k.confdeltype, k.confupdtype, rn.nspname AS ref_schema, r.relname AS ref_table,
            a.attname AS name, ra.attname AS ref_name, s.n AS position
            FROM pg_catalog.pg_constraint k
            CROSS JOIN LATERAL generate_subscripts(k.conkey,1) s(n)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[s.n]
            LEFT JOIN pg_catalog.pg_class r ON r.oid = k.confrelid
            LEFT JOIN pg_catalog.pg_namespace rn ON rn.oid = r.relnamespace
            LEFT JOIN pg_catalog.pg_attribute ra ON ra.attrelid = k.confrelid AND ra.attnum = k.confkey[s.n]
            WHERE k.conrelid = :relation::regclass ORDER BY k.oid, s.n} $params]
        set groups {}
        foreach row $constraints {dict lappend groups [dict get $row oid] $row}
        dict for {id rows} $groups {
            set names [lmap row $rows {dict get $row name}]
            set row [lindex $rows 0]
            switch -- [dict get $row contype] {
                p {
                    set pk $names
                    if {[llength $pk] == 1 && [dict exists [lindex [dict get $columns [lindex $pk 0]] 1] auto_increment]} {set pk {}}
                }
                u {lappend unique [_jsonStrings $names]}
                f {
                    if {[dict get $row ref_schema] ne $schema} {_fail UNSUPPORTED "cross-schema foreign keys are not supported in backups"}
                    set actions {a {no action} r restrict c cascade n {set null} d {set default}}
                    dict set foreign $id [dict create table [list S [dict get $row ref_table]] columns [_jsonStrings $names] referenced_columns [_jsonStrings [lmap r $rows {dict get $r ref_name}]] on_delete [list S [dict get $actions [dict get $row confdeltype]]] on_update [list S [dict get $actions [dict get $row confupdtype]]]]
                }
            }
        }
        set rows [_raw $handle {SELECT ic.relname AS name, i.indisunique AS is_unique, a.attname AS column_name,
            (i.indoption[s.n] & 1) = 1 AS descending,
            (i.indoption[s.n] & 2) = 2 AS nulls_first,
            i.indpred IS NOT NULL OR i.indexprs IS NOT NULL OR i.indnkeyatts <> i.indnatts OR NOT i.indisvalid OR i.indnullsnotdistinct OR am.amname <> 'btree' OR i.indcollation[s.n] <> a.attcollation OR NOT opc.opcdefault AS unsupported
            FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_catalog.pg_am am ON am.oid = ic.relam
            CROSS JOIN LATERAL generate_series(0,i.indnkeyatts-1) s(n)
            LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[s.n]
            JOIN pg_catalog.pg_opclass opc ON opc.oid = i.indclass[s.n]
            WHERE i.indrelid = :relation::regclass AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conindid = i.indexrelid AND k.contype IN ('p','u'))
            ORDER BY ic.relname, s.n} $params]
        set groups {}
        foreach row $rows {
            if {[dict get $row unsupported] || [dict get $row descending] != [dict get $row nulls_first] || ![dict exists $row column_name]} {_fail UNSUPPORTED "index cannot be represented by a portable JSON schema"}
            dict lappend groups [dict get $row name] $row
        }
        dict for {index rows} $groups {
            set names {}; set desc {}
            foreach row $rows {lappend names [dict get $row column_name]; if {[dict get $row descending]} {lappend desc [dict get $row column_name]}}
            lappend indexes [list M [dict create name [list S $index] columns [_jsonStrings $names] unique [list BOOL [dict get [lindex $rows 0] is_unique]] descending [_jsonStrings $desc]]]
        }
    }
    set result [dict create name [list S $name] columns [list M $columns]]
    if {[llength $pk]} {dict set result primary_key [_jsonStrings $pk]}
    if {[llength $unique]} {dict set result unique [list L $unique]}
    if {[llength $indexes]} {dict set result indexes [list L $indexes]}
    if {[dict size $foreign]} {dict set result foreign_keys [list L [lmap fk [dict values $foreign] {list M $fk}]]}
    return [list M $result]
}

# Parents precede children. Cyclic schemas require a richer migration format.
proc ::tpersist::_backupOrder {definitions} {
    set remaining {}; set ordered {}
    foreach definition $definitions {dict set remaining [dict get $definition name] $definition}
    while {[dict size $remaining]} {
        set progress 0
        dict for {name definition} $remaining {
            set blocked 0
            if {[dict exists $definition foreign_keys]} {
                foreach fk [dict get $definition foreign_keys] {
                    set parent [dict get [_tableParts [dict get $fk table]] name]
                    if {[dict exists $remaining $parent]} {set blocked 1; break}
                }
            }
            if {$blocked} continue
            lappend ordered $definition
            dict unset remaining $name
            set progress 1
        }
        if {!$progress} {_fail UNSUPPORTED "cyclic or self-referencing foreign keys are not supported in JSONL backups"}
    }
    return $ordered
}
