# tpersist

A Tcl extension for building SQL statements and accessing SQLite, PostgreSQL,
and MySQL through TDBC. Inspired by SQLAlchemy Core, with ordinary commands
and reusable Tcl dictionaries.

Generated **With help from AI**.

```tcl
package require tpersist
namespace import ::tpersist::db_*

set query [db_select users -expr {id, name}]
set query [db_where $query -expr {age >= 18}]
set query [db_limit [db_order_by $query -expr {name}] 20]
puts [dict get [db_compile $query] sql]
```

Build with CMake and Tcl 8.6 or 9 development headers:

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
cmake --install build
```

Database execution requires the corresponding `tdbc::sqlite3`,
`tdbc::postgres`, or `tdbc::mysql` package. SQLite is the default dialect.
JSON schema loading requires `tjson 1.0.27` or newer; other APIs do not load it.

- [Runnable examples](examples/readme.md)
- [API reference](docs/api.md)
- [Versioned JSON schemas](docs/schema-json.md)
- [Optional TclOO layer](docs/oo.md)
- [Building and testing](docs/development.md)

MIT licensed. This is an initial implementation of a Core-style SQL toolkit;
it does not implement SQLAlchemy's ORM.

`::tpersist::db_dialect $connection` returns `sqlite`, `postgresql`, or `mysql`
for an open connection; an unknown or closed handle raises `TPERSIST CONNECTION`.
Adapters use this to validate a borrowed connection.

`db_create_index connection name table columns -descending {column ...}` marks
selected index columns as descending; all remaining columns stay ascending.
For example, `{domain published_at path} -descending published_at` supports
`ORDER BY published_at DESC, path ASC` within a domain. Descending columns must
belong to the index and remain quoted identifiers, not SQL fragments.

Apply a package schema stored under `sql/`:

```tcl
::tpersist::db_apply_schema $connection [file join $packageDir sql schema.json]
```

This creates missing tables and indexes. Pass `-additive true` to also add
missing columns to existing tables. Existing definitions are left intact.
