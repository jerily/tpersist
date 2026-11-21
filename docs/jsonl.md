# JSONL schema and data backups

The minimum database versions for JSONL backups are SQLite 3.37 and PostgreSQL 15.
Starting with tpersist 0.1.7, export and import load `tjson 1.0.30` or newer
on first use. They require a connection with no active transaction and own
their snapshot or import transaction.

```tcl
package require tpersist 0.1.7
namespace import ::tpersist::db_*
set db [db_connect -database application.sqlite3 -autobegin false]

# All application tables in the current schema, or an explicit selection.
puts [db_tables $db]
db_export_jsonl $db backup.jsonl.gz
db_export_jsonl $db accounts.jsonl -tables {users profiles}

set target [db_connect -database restored.sqlite3 -autobegin false]
db_import_jsonl $target backup.jsonl.gz
db_disconnect $target
db_disconnect $db
```

`db_tables connection ?-schema name?` returns sorted application table names.
SQLite defaults to `main`; PostgreSQL defaults to `current_schema()`. PostgreSQL
system schemas and extension-owned tables, SQLite internals and shadow tables,
and views are excluded. Virtual/partitioned tables are discovered but export
rejects them because the portable schema cannot reconstruct them. Use `-schema`
for another schema or attached SQLite database; a call operates on one schema.
Table names are literal identifiers, including spaces and dots, not patterns or
SQL fragments. Qualified names use the separate `-schema` option.

Both `db_export_jsonl connection path ?options?` and
`db_import_jsonl connection path ?options?` return a dictionary of table row
counts, including empty tables. Options:

| Option | Behavior |
| --- | --- |
| `-tables {name ...}` | Only these tables; omission selects all, `{}` selects none. Unknown or duplicate names fail. Import selections refer to the archive. |
| `-schema name` | Source or destination schema. It must already exist. Table names in the archive are unqualified so another destination schema can be used. |
| `-gzip boolean` | Defaults to true for a `.gz` filename, false otherwise. |
| `-deadline milliseconds` | Absolute Unix time in milliseconds, checked between batches/rows. Set driver statement/lock timeouts separately to bound blocked queries. |
| `-max_bytes bytes` | Maximum file size (compressed size for gzip). Checked during and after export, or before import. |

Export reads one consistent snapshot (repeatable read on PostgreSQL). It writes
a private temporary file beside the destination and renames it only after
completion. Failure removes the temporary file and preserves an existing backup.
PostgreSQL fetches 256 rows per cursor batch; SQLite iterates its result set.
Memory is bounded by schema metadata, a batch of rows and the largest JSONL record.

The first record has `format: "tpersist"`, `version: 1`, source `dialect`,
`created_at`, and `schema`. The embedded schema is the same version 1 JSON format
accepted by `db_read_schema`, captured from live database catalogs. It includes
columns, literal defaults, primary/unique keys, foreign keys, identity columns,
and ordinary indexes with descending columns. Package schema files are not read.
Each data record has `table` and `values`; the final `complete: true` record has
counts for every table. A backup is a single JSONL file, optionally gzip compressed,
so schemas and rows cannot be separated during upload or download.

Version 1 archives from earlier releases can be restored within the JSONL
record limits. Each UTF-8 record can contain up to 1 MiB before its line ending
and up to 32 levels of nesting. These limits apply to the whole schema header
and to each encoded row, including base64 expansion, before compression.
`-max_bytes` independently limits the archive file size. Import accepts LF,
CRLF, and a final footer without a newline. A blank, malformed, or oversized
record raises `TJSON STRICT`.

Non-null scalar values are JSON strings, preserving bigint/decimal precision and
numeric-looking text. SQL NULL is JSON null, binary values are base64 strings,
and text containing NUL uses an object `{"utf8": "<base64 UTF-8>"}`. The archived
column type determines binding. This is a versioned interchange format, not a
plain JSON serialization of database rows. Database type conversions still apply
when importing into another dialect, especially SQLite numeric affinity.
Some older Tcl 8.6 PostgreSQL drivers reject supplementary Unicode characters;
use a current Tcl 9/TDBC runtime when restoring data containing those characters.

Import creates missing tables and indexes from the archived schema. It requires
existing selected tables to be empty and to match the archived table definition;
conflicting indexes also fail. It neither truncates nor drops application tables.
Selected tables and their data are restored in one transaction, including DDL.
Malformed records, duplicates, count mismatches, a missing footer, records after
the footer, or gzip checksum errors roll back the import. Existing unselected
tables remain unchanged. Identity generators advance past restored identifiers.
PostgreSQL uses transactional sequence restarts.

Parent tables precede child tables. Selection does not automatically include
foreign-key dependencies: include parents or provision them in the destination.
The importer validates the entire archive even when selecting only some tables.
Import into a database that is not being used by the application.

The initial schema snapshot implementation supports the portable tpersist schema
vocabulary. It rejects MySQL, custom types/collations, generated columns,
expression defaults (including PostgreSQL serial/`nextval` defaults), checks,
triggers, row security, partitioning/inheritance, deferrable/cyclic/self-referencing
foreign keys, partial/expression/covering indexes, and other detected features it
cannot faithfully reconstruct. Custom identity sequence settings are rejected;
sequence counters above the maximum retained row ID are not archived. Roles,
grants, views, extensions and external application secrets are not backed up.
Keep native database backups when those objects or features are needed.

On PostgreSQL 18, the catalog check also rejects tables with `NOT NULL`
constraints, including primary keys. This limitation also applies to tpersist 0.1.6.
