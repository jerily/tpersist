# Copyright Jerily LTD. All Rights Reserved.
# SPDX-License-Identifier: MIT.

# Full-text fields have a durable application key. The physical names and
# query contract are shared with the offline compiler.
proc ::tpersist::_ftsValidate {definition pk} {
    set columns [dict get $definition columns]
    foreach name [list [dict get $definition name] {*}[dict keys $columns]] {
        if {[string match -nocase __tpfts_* $name]} {_fail VALIDATION "reserved full-text identifier: $name"}
    }
    if {![dict exists $definition virtual]} return
    set seen {}
    foreach name [dict keys $columns] {dict set seen [string tolower $name] 1}
    dict for {field spec} [dict get $definition virtual] {
        _quote $field sqlite
        if {[string length $field] > 255 || [string match -nocase __tpfts_* $field] || [dict exists $seen [string tolower $field]]} {
            _fail VALIDATION "invalid or duplicate virtual field: $field"
        }
        dict set seen [string tolower $field] 1
        if {[dict exists $seen _rowid_]} {_fail VALIDATION "full-text tables reserve the _rowid_ identifier"}
        _fields $spec {type document_id columns}
        if {[dict get $spec type] ne "fulltext"} {_fail VALIDATION "unsupported virtual field type for $field"}
        set id [dict get $spec document_id]
        if {![dict exists $columns $id] || [dict get $columns $id type] ni {integer bigint}} {
            _fail VALIDATION "full-text document_id $id must name an integer or bigint column"
        }
        set singlePK [expr {[llength $pk] == 1 && [lindex $pk 0] eq $id}]
        set unique [_flag [dict get $columns $id] unique]
        if {[dict exists $definition unique] && [list $id] in [dict get $definition unique]} {set unique 1}
        if {!$singlePK && (!$unique || ![_flag [dict get $columns $id] not_null])} {
            _fail VALIDATION "full-text document_id $id requires a single-column primary key or NOT NULL UNIQUE constraint"
        }
        _columnList [dict get $spec columns] $columns sqlite
        foreach source [dict get $spec columns] {
            if {[dict get $columns $source type] ni {text varchar}} {_fail VALIDATION "full-text source $source must be text or varchar"}
        }
    }
}

proc ::tpersist::_ftsTransaction {handle body} {
    if {[db_dialect $handle] eq "mysql"} {
        if {[dict get [_connection $handle] transaction]} {_fail TRANSACTION "MySQL full-text DDL requires no active transaction"}
        return [uplevel 1 $body]
    }
    return [uplevel 1 [list ::tpersist::db_transaction $handle $body]]
}

# Look in the table's creation schema, even if another schema earlier in a
# search path contains objects with the same names.
proc ::tpersist::_ftsSchema {handle table} {
    set ref [_tableParts $table]
    if {[dict exists $ref schema]} {return [dict get $ref schema]}
    switch -- [db_dialect $handle] {
        sqlite {return main}
        postgresql {set sql {SELECT current_schema() AS name}}
        mysql {set sql {SELECT DATABASE() AS name}}
    }
    return [dict get [lindex [_raw $handle $sql] 0] name]
}

# The marker column distinguishes the internal catalog from a name collision.
# When it is occupied by an unrelated object, CREATE (without IF NOT EXISTS)
# will fail instead of adopting the object.
proc ::tpersist::_ftsHasCatalog {handle table} {
    set ref [_tableParts $table]
    set schema {}
    if {[dict exists $ref schema]} {set schema [dict get $ref schema]}
    set params [dict create schema $schema]
    switch -- [db_dialect $handle] {
        sqlite {set sql {SELECT name AS marker FROM pragma_table_info('__tpfts_catalog', COALESCE(NULLIF(:schema,''),'main')) WHERE name = 'tpersist_fts_v1'}}
        postgresql {set sql {SELECT column_name AS marker FROM information_schema.columns WHERE table_schema = COALESCE(NULLIF(:schema,''),current_schema()) AND table_name = '__tpfts_catalog' AND column_name = 'tpersist_fts_v1'}}
        mysql {set sql {SELECT column_name AS marker FROM information_schema.columns WHERE table_schema = COALESCE(NULLIF(:schema,''),DATABASE()) AND table_name = '__tpfts_catalog' AND column_name = 'tpersist_fts_v1'}}
    }
    return [dict exists [lindex [_raw $handle $sql $params] 0] marker]
}

proc ::tpersist::_ftsQualified {schema name dialect} {
    return "[_quote $schema $dialect].[_quote $name $dialect]"
}

proc ::tpersist::_ftsCatalog {handle table} {
    return [_ftsQualified [_ftsSchema $handle $table] __tpfts_catalog [db_dialect $handle]]
}

# Check extension availability and ownership before creating even the base table.
proc ::tpersist::_ftsCheckCatalog {handle table} {
    set schema [_ftsSchema $handle $table]
    set params [dict create schema $schema]
    switch -- [db_dialect $handle] {
        sqlite {
            if {![llength [_raw $handle {SELECT 1 FROM pragma_module_list WHERE name = 'fts5'}]]} {
                _fail UNSUPPORTED "SQLite full-text fields require the FTS5 module"
            }
            set sql "SELECT 1 FROM [_quote $schema sqlite].sqlite_schema WHERE name = '__tpfts_catalog' COLLATE NOCASE"
            set params {}
        }
        postgresql {set sql {SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = :schema AND c.relname = '__tpfts_catalog'}}
        mysql {set sql {SELECT 1 FROM information_schema.tables WHERE table_schema = :schema AND table_name = '__tpfts_catalog'}}
    }
    if {[llength [_raw $handle $sql $params]] && ![_ftsHasCatalog $handle $table]} {
        _fail SCHEMA "an unrelated database object occupies the full-text catalog name"
    }
}

proc ::tpersist::_ftsRecords {handle table} {
    if {![_ftsHasCatalog $handle $table]} {return {}}
    set cat [_ftsCatalog $handle $table]
    set base [dict get [_tableParts $table] name]
    set records {}
    foreach row [_raw $handle "SELECT field_name, doc_id, sources, phase, signature FROM $cat WHERE base_name = :base" [dict create base $base]] {
        dict set records [dict get $row field_name] $row
    }
    return $records
}

proc ::tpersist::_ftsDefinition {row} {
    return [dict create type fulltext document_id [dict get $row doc_id] columns [dict get $row sources]]
}

proc ::tpersist::_ftsDefinitions {handle table} {
    set fields {}
    dict for {field row} [_ftsRecords $handle $table] {
        if {[dict get $row phase] ne "ready"} {_fail SCHEMA "unfinished full-text schema application for $field"}
        set live [_ftsSnapshot $handle $table $field]
        if {![_ftsHealthy $field $row $live]} {_fail SCHEMA "incomplete full-text field $field"}
        dict set fields $field [_ftsDefinition $row]
    }
    return $fields
}

proc ::tpersist::_ftsManagedTables {handle schema} {
    set table [db_table __tpfts_catalog]
    if {$schema ne {}} {dict set table schema $schema}
    if {![_ftsHasCatalog $handle $table]} {return {}}
    set names {__tpfts_catalog}
    if {[db_dialect $handle] eq "sqlite"} {
        set cat [_ftsCatalog $handle $table]
        foreach row [_raw $handle "SELECT base_name, field_name FROM $cat"] {
            lappend names [_ftsName [dict get $row base_name] [dict get $row field_name] fts]
        }
    }
    return $names
}

proc ::tpersist::_ftsRoles {dialect} {
    if {$dialect eq "sqlite"} {return {keys fts ai au ad}}
    return {column idx}
}

# Capture the native definitions, including membership and expressions, to
# distinguish missing owned objects from same-name objects replaced by a DBA.
proc ::tpersist::_ftsSnapshot {handle table field} {
    set dialect [db_dialect $handle]
    set schema [_ftsSchema $handle $table]
    set base [dict get [_tableParts $table] name]
    set result {}
    foreach role [_ftsRoles $dialect] {
        set name [_ftsName $base $field $role]
        switch -- $dialect {
            sqlite {
                set sql "SELECT type, tbl_name, sql FROM [_quote $schema sqlite].sqlite_schema WHERE name = :name COLLATE NOCASE"
                set params [dict create name $name]
            }
            postgresql {
                if {$role eq "column"} {
                    set sql {SELECT a.attgenerated, pg_catalog.format_type(a.atttypid, a.atttypmod) AS coltype, pg_catalog.pg_get_expr(d.adbin,d.adrelid) AS expression
                        FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                        LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
                        WHERE n.nspname = :schema AND c.relname = :base AND a.attname = :name AND a.attnum > 0 AND NOT a.attisdropped}
                    set params [dict create schema $schema base $base name $name]
                } else {
                    set sql {SELECT c.relkind, CASE WHEN c.relkind = 'i' THEN pg_catalog.pg_get_indexdef(c.oid) END AS definition, i.indisvalid
                        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                        LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid WHERE n.nspname = :schema AND c.relname = :name}
                    set params [dict create schema $schema name $name]
                }
            }
            mysql {
                if {$role eq "column"} {
                    set sql {SELECT column_name AS physical_name, data_type AS native_type, extra AS attributes,
                        generation_expression AS expression_sql, hex(convert(generation_expression USING latin1)) AS expression_bytes,
                        character_set_name AS charset, collation_name AS text_collation FROM information_schema.columns
                        WHERE table_schema = :schema AND table_name = :base AND column_name = :name}
                } else {
                    set sql {SELECT index_type AS method, column_name AS physical_name, seq_in_index AS position FROM information_schema.statistics
                        WHERE table_schema = :schema AND table_name = :base AND index_name = :name ORDER BY seq_in_index}
                }
                set params [dict create schema $schema base $base name $name]
            }
        }
        set rows [_raw $handle $sql $params]
        if {[llength $rows]} {dict set result $role $rows}
    }
    return $result
}

proc ::tpersist::_ftsHealthy {field record live} {
    set signature [dict get $record signature]
    dict for {role value} $live {
        if {[dict exists $signature $role] && [dict get $signature $role] ne $value} {
            # A MySQL ALTER may have committed before the final catalog update.
            # Accept either the previously recorded native signature or the
            # exact expression and index described by the pending record.
            if {[dict get $record phase] eq "replacing" && [_ftsMysqlPair $live $record]} continue
            _fail SCHEMA "full-text $field has a conflicting $role object"
        }
    }
    if {[dict get $record phase] eq "creating" && [dict size $live] && ![_ftsMysqlPair $live $record]} {
        _fail SCHEMA "full-text $field has conflicting objects after an interrupted creation"
    }
    return [expr {[dict get $record phase] eq "ready" && [dict size $live] == [dict size $signature]}]
}

proc ::tpersist::_ftsMysqlPair {live record} {
    if {![dict exists $live column] || ![dict exists $live idx]} {return 0}
    set column [lindex [dict get $live column] 0]
    set indexes [dict get $live idx]
    if {[llength $indexes] != 1 || ![dict exists $column native_type] ||
        [dict get $column native_type] ne "longtext" || [dict get $column charset] ne "utf8mb4" ||
        [dict get $column attributes] ne "STORED GENERATED INVISIBLE" ||
        [dict get [lindex $indexes 0] method] ne "FULLTEXT" ||
        [dict get [lindex $indexes 0] physical_name] ne [dict get $column physical_name]} {return 0}
    set columns [lmap name [dict get $record sources] {_quote $name mysql}]
    set expression "concat_ws(_utf8mb4' ',[join $columns ,])"
    # INFORMATION_SCHEMA escapes the serialized expression, including quotes in
    # its separator. MySQL 8.4 also reports UTF-8 identifier bytes as latin1 in
    # this field. Compare complete expressions in the two catalog encodings.
    set expected [string map [list \\ \\\\ ' \\' \n \\n \r \\r \x1a \\Z] $expression]
    set bytes [binary encode hex [encoding convertto utf-8 $expected]]
    return [expr {[dict get $column expression_sql] eq $expected ||
        [string equal -nocase [dict get $column expression_bytes] $bytes]}]
}

# Compute all decisions before schema application emits any DDL.
proc ::tpersist::_ftsPlan {handle table additive} {
    set wanted {}
    if {[dict exists $table virtual]} {set wanted [dict get $table virtual]}
    if {!$additive && ![dict size $wanted]} {return {}}
    if {[dict size $wanted]} {_ftsCheckCatalog $handle $table}
    set records [_ftsRecords $handle $table]
    set plan {}
    dict for {field spec} $wanted {
        set live [_ftsSnapshot $handle $table $field]
        if {![dict exists $records $field]} {
            if {[dict size $live]} {_fail SCHEMA "full-text $field collides with an existing database object"}
            lappend plan [list create $field $spec]
            continue
        }
        set row [dict get $records $field]
        set healthy [_ftsHealthy $field $row $live]
        set same [expr {[dict get $row doc_id] eq [dict get $spec document_id] && [dict get $row sources] eq [dict get $spec columns]}]
        if {$healthy && $same} continue
        if {!$additive && [dict get $row phase] eq "ready"} {
            _fail SCHEMA "full-text $field changed or is incomplete; apply with -additive true"
        }
        if {[db_dialect $handle] eq "mysql" && [dict size $live] == 2} {
            lappend plan [list replace $field $spec]
        } else {
            lappend plan [list drop $field] [list create $field $spec]
        }
    }
    if {$additive} {
        dict for {field row} $records {
            if {[dict exists $wanted $field]} continue
            _ftsHealthy $field $row [_ftsSnapshot $handle $table $field]
            lappend plan [list drop $field]
        }
    }
    return $plan
}

proc ::tpersist::_ftsEnsureCatalog {handle table} {
    if {[_ftsHasCatalog $handle $table]} return
    set cat [_ftsCatalog $handle $table]
    set text [expr {[db_dialect $handle] eq "mysql" ? "LONGTEXT" : "TEXT"}]
    set sql "CREATE TABLE $cat (tpersist_fts_v1 INTEGER NOT NULL DEFAULT 1, base_name VARCHAR(255) NOT NULL,
        field_name VARCHAR(255) NOT NULL, doc_id TEXT NOT NULL, sources $text NOT NULL,
        phase VARCHAR(16) NOT NULL, signature $text NOT NULL, PRIMARY KEY (base_name, field_name))"
    if {[db_dialect $handle] eq "mysql"} {append sql " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"}
    _ddl $handle $sql
}

proc ::tpersist::_ftsCreate {handle table field spec {replace 0}} {
    set dialect [db_dialect $handle]
    set schema [_ftsSchema $handle $table]
    set base [dict get [_tableParts $table] name]
    set relation [_ftsQualified $schema $base $dialect]
    set names {}
    foreach role [_ftsRoles $dialect] {
        dict set names $role [_ftsName $base $field $role]
    }
    set id [_quote [dict get $spec document_id] $dialect]
    set columns [lmap name [dict get $spec columns] {_quote $name $dialect}]
    if {$dialect eq "sqlite"} {
        set view [dict get $names keys]
        set fts [dict get $names fts]
        set fq [_quote $fts sqlite]
        set vq [_ftsQualified $schema $view sqlite]
        set ft [_ftsQualified $schema $fts sqlite]
        set bq [_quote $base sqlite]
        foreach prefix {{} old. new.} {
            set parts [lmap q $columns {format {coalesce(%s%s,'')} $prefix $q}]
            dict set content $prefix [join $parts " || ' ' || "]
        }
        if {[llength [_raw $handle "SELECT 1 FROM $relation WHERE typeof($id) <> 'integer' LIMIT 1"]]} {
            _fail SCHEMA "full-text document_id must contain only non-null integers"
        }
        _ddl $handle "CREATE VIEW $vq AS SELECT _rowid_ AS source_rowid, $id AS docid, [dict get $content {}] AS body FROM $bq"
        set viewLiteral [_defaultSql [db_value $view -type text] sqlite]
        _ddl $handle "CREATE VIRTUAL TABLE $ft USING fts5(body, content=$viewLiteral, content_rowid='docid', tokenize='unicode61')"
        set guard "SELECT CASE WHEN typeof(new.$id) <> 'integer' THEN RAISE(ABORT,'full-text document_id must be an integer') END;"
        set insert "INSERT INTO ${fq}(rowid,body) VALUES (new.$id,[dict get $content new.]);"
        set delete "INSERT INTO ${fq}($fq,rowid,body) VALUES ('delete',old.$id,[dict get $content old.]);"
        foreach {role event body} [list ai INSERT "$guard $insert" ad DELETE $delete au UPDATE "$guard $delete $insert"] {
            _ddl $handle "CREATE TRIGGER [_ftsQualified $schema [dict get $names $role] sqlite] AFTER $event ON $bq BEGIN $body END"
        }
        _ddl $handle "INSERT INTO ${ft}($fq) VALUES('rebuild')"
    } else {
        set column [_quote [dict get $names column] $dialect]
        set index [_quote [dict get $names idx] $dialect]
        if {$dialect eq "postgresql"} {
            set parts [lmap q $columns {format {coalesce(%s,'')} $q}]
            set text [join $parts " || ' ' || "]
            _ddl $handle "ALTER TABLE $relation ADD COLUMN $column tsvector GENERATED ALWAYS AS (pg_catalog.to_tsvector('pg_catalog.simple'::regconfig, $text)) STORED"
            _ddl $handle "CREATE INDEX $index ON $relation USING GIN ($column)"
        } else {
            set drop [expr {$replace ? "DROP INDEX $index, DROP COLUMN $column, " : ""}]
            _ddl $handle "ALTER TABLE $relation ${drop}ADD COLUMN $column LONGTEXT CHARACTER SET utf8mb4 GENERATED ALWAYS AS (CONCAT_WS(_utf8mb4' ', [join $columns {, }])) STORED INVISIBLE, ADD FULLTEXT INDEX $index ($column)"
        }
    }
}

proc ::tpersist::_ftsDrop {handle table field} {
    set dialect [db_dialect $handle]
    set schema [_ftsSchema $handle $table]
    set base [dict get [_tableParts $table] name]
    set relation [_ftsQualified $schema $base $dialect]
    set live [_ftsSnapshot $handle $table $field]
    switch -- $dialect {
        sqlite {
            foreach {role type} {ai TRIGGER au TRIGGER ad TRIGGER fts TABLE keys VIEW} {
                if {[dict exists $live $role]} {_ddl $handle "DROP $type [_ftsQualified $schema [_ftsName $base $field $role] $dialect]"}
            }
        }
        postgresql {
            if {[dict exists $live idx]} {_ddl $handle "DROP INDEX [_ftsQualified $schema [_ftsName $base $field idx] $dialect]"}
            if {[dict exists $live column]} {_ddl $handle "ALTER TABLE $relation DROP COLUMN [_quote [_ftsName $base $field column] $dialect]"}
        }
        mysql {
            set parts {}
            foreach {role type} {idx INDEX column COLUMN} {
                if {[dict exists $live $role]} {lappend parts "DROP $type [_quote [_ftsName $base $field $role] $dialect]"}
            }
            if {[llength $parts]} {_ddl $handle "ALTER TABLE $relation [join $parts {, }]"}
        }
    }
}

proc ::tpersist::_ftsExecute {handle table plan} {
    if {[dict exists $table virtual]} {
        dict for {field spec} [dict get $table virtual] {_ftsValidateLive $handle $table $spec}
    }
    if {![llength $plan]} return
    _ftsEnsureCatalog $handle $table
    set cat [_ftsCatalog $handle $table]
    set base [dict get [_tableParts $table] name]
    foreach entry $plan {
        lassign $entry action field spec
        set key [dict create base $base field $field]
        set predicate "base_name = :base AND field_name = :field"
        if {$action eq "drop"} {
            # MySQL commits DDL independently. Record intent before ALTER so
            # reapplication can finish a drop after a disconnect.
            _raw $handle "UPDATE $cat SET phase = 'dropping' WHERE $predicate" $key
            _ftsDrop $handle $table $field
            _raw $handle "DELETE FROM $cat WHERE $predicate" $key
        } else {
            set params [dict merge $key [dict create doc [dict get $spec document_id] sources [dict get $spec columns]]]
            if {$action eq "replace"} {
                _raw $handle "UPDATE $cat SET phase='replacing', doc_id=:doc, sources=:sources WHERE $predicate" $params
            } else {
                if {[dict size [_ftsSnapshot $handle $table $field]]} {_fail SCHEMA "full-text $field collides with an existing database object"}
                _raw $handle "INSERT INTO $cat (base_name,field_name,doc_id,sources,phase,signature)
                    VALUES (:base,:field,:doc,:sources,'creating','')" $params
            }
            _ftsCreate $handle $table $field $spec [expr {$action eq "replace"}]
            set signature [_ftsSnapshot $handle $table $field]
            if {[dict size $signature] != [llength [_ftsRoles [db_dialect $handle]]]} {_fail SCHEMA "failed to verify new full-text field $field"}
            _raw $handle "UPDATE $cat SET phase = 'ready', signature = :signature WHERE $predicate" [dict merge $key [dict create signature $signature]]
        }
    }
}

proc ::tpersist::_ftsApply {handle table additive} {
    set plan [_ftsPlan $handle $table $additive]
    _ftsTransaction $handle {_ftsExecute $handle $table $plan}
}
