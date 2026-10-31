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
No JSON dependency is required.

- [Runnable examples](examples/readme.md)
- [API reference](docs/api.md)
- [Optional TclOO layer](docs/oo.md)
- [Building and testing](docs/development.md)

MIT licensed. This is an initial implementation of a Core-style SQL toolkit;
it does not implement SQLAlchemy's ORM.
