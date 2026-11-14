# JSON schema files

Store package schemas in `sql/schema.json` (or named files under `sql/`).
Examples use `examples/sql/`; tests use `tests/sql/`. Resolve paths relative to
`[info script]`, and include `sql/` when installing a package.

```tcl
# In a package's top-level Tcl script.
set schema [file join [file dirname [info script]] sql schema.json]
::tpersist::db_apply_schema $connection $schema
```

The loader uses `tjson 1.0.27` or newer. It never evaluates schema text as Tcl or
accepts SQL expressions as defaults. See the runnable
[example](../examples/07_json_schema.tcl) and its
[schema](../examples/sql/users.json).

## Format version 1

```json
{
  "version": 1,
  "tables": [
    {
      "name": "users",
      "columns": {
        "id": {"type": "integer", "primary_key": true, "auto_increment": true},
        "email": {"type": "varchar", "length": 255, "not_null": true}
      },
      "indexes": [
        {"name": "users_email", "columns": ["email"], "unique": true}
      ]
    }
  ]
}
```

`version` identifies the **file format**, not a database migration revision.
Only version `1` is supported. Add tables or indexes to the file and reapply it
without changing this number. There is no migration ledger.

| Field | Meaning |
|---|---|
| `tables` | Required array; tables are created in file order. |
| Table `name`, `columns` | Required name and object mapping column names to specifications. |
| Table `schema` | Optional SQL schema/database name, separate from `name`. |
| Table `primary_key` | Optional array of column names for a composite key. |
| Table `unique` | Optional array of column-name arrays. |
| Table `foreign_keys` | Optional array of foreign-key objects. |
| Table `indexes` | Optional array of indexes on this table. |
| Index `name`, `columns` | Required name and ordered array of column names. |
| Index `unique` | Optional boolean, default `false`. |
| Index `descending` | Optional array naming indexed columns to sort descending. Others ascend. |

Column specifications use the [DDL API's types and options](api.md#schema-definitions).
`type` is required. Flags (`primary_key`, `not_null`, `unique`, `auto_increment`)
are JSON booleans; `length`, `precision`, and `scale` are integer numbers.

A foreign key has `columns`, `table`, and `referenced_columns`; optional
`on_delete` and `on_update` use the existing DDL action names. Its `table` may be
a string or `{"name": "users", "schema": "public"}`. List referenced tables
first. SQL schemas/databases themselves must already exist.

Defaults are literals, with their SQL type taken from the column:

- `null` produces SQL NULL; an omitted default produces no DEFAULT clause.
- Text, varchar, date, and timestamp defaults are strings; booleans use `true`/`false`.
- Integer/bigint defaults accept numbers or numeric strings. Use strings for
  integers outside ±9007199254740991; larger JSON numbers are rejected to avoid
  rounding in `tjson`.
- Decimal defaults must be strings, such as `"1234567890.12"`, to preserve precision.
- Real/double defaults accept numbers or numeric strings. Binary defaults support
  only `null`.

Unknown fields, duplicate object fields, duplicate table/index names, invalid
constraints, and unsupported versions are rejected. Use schema-wide unique
index names for portability.

## Procedures

`db_read_schema filename` reads UTF-8 JSON and returns a dictionary with:

- `version`: `1`.
- `tables`: validated `db_define_table` dictionaries, in file order.
- `indexes`: dictionaries with `name`, `table`, `columns`, `unique`, and `descending`.

Reading does no database work. Pass a returned table to `db_schema_sql` to inspect
its DDL for a selected dialect.

`db_apply_schema connection filename ?-additive boolean?` validates every definition for the connection's
dialect, then invokes `db_create_table` for all tables and `db_create_index` for
all indexes. It returns an empty result on success. SQLite and PostgreSQL use
`IF NOT EXISTS`; MySQL checks `information_schema.statistics` for existing indexes.
These catalog reads do not trigger autobegin.

`-additive` defaults to `false`: only missing tables and indexes are created.
Set it to `true` to add missing columns to existing tables from the same JSON file:

```tcl
::tpersist::db_apply_schema $connection $schema -additive true
```

Column additions are validated before any DDL and run before index creation.
Existing column types/defaults and index definitions are left intact; removing
an entry never drops it. New columns may be nullable or have a literal default.
A new NOT NULL column requires a non-null default. Adding primary-key, identity,
inline UNIQUE, or foreign-key columns requires a migration; a separate named
unique index is supported. These limits apply only to existing tables.

Concurrent additive applications must be serialized by the caller. Database errors propagate, and earlier DDL may have succeeded.
For atomic application on SQLite/PostgreSQL, wrap the call in `db_transaction`.
MySQL requires no active transaction and concurrent schema application should be
serialized by the caller.

Malformed JSON raises `TPERSIST JSON`; invalid file structure raises
`TPERSIST SCHEMA`. Existing DDL validation and database errors retain their categories.

## Future migrations

Reserve `sql/migrations/` for ordered migration files, such as
`0002_rename_profile_column.json`, covering renames, type changes, constraint
changes, drops, and data backfills. A future migration runner should record
applied migrations in the database. This release does not execute migration
files; `version: 1` continues to identify the schema file format.
