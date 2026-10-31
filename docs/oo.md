# Optional TclOO convenience layer

`tpersist::oo` is a separate package implemented entirely on top of the public
`db_*` API. Requiring `tpersist` alone does not load these classes.

```tcl
package require tpersist::oo
namespace import ::tpersist::db_*

set database [::tpersist::oo::Database new -database app.sqlite]
try {
    set query [$database select users -columns {id name}]
    $query where [db_ge [db_col age] [db_value 18 -type integer]]
    $query order_by name
    $query limit 20
    set rows [$query all]
} finally {
    $database destroy
}
```

The wrapper offers mutable query objects. Each composition method updates that
object's statement dictionary and returns the same object for chaining. The
procedural builders retain their original value semantics. Use `$query fork`
to create an independent branch; assigning the object command name to another
variable merely creates another reference to the same mutable object.

## Database

`::tpersist::oo::Database new ?connectionOptions...?` uses `db_connect` options.

| Method | Meaning |
|---|---|
| `select`, `insert`, `update`, `delete` | Same arguments as their `db_*` constructors; return connected queries |
| `query statement` | Wrap an existing dictionary in a connected query |
| `execute statementOrQuery ?options...?` | Execute a dictionary or query; return the full result dictionary |
| `transaction script` | Same caller-scope and transaction behavior as `db_transaction` |
| `begin`, `commit`, `rollback` | Explicit connection transaction control |
| `create_table`, `drop_table`, `create_index` | Same arguments as the procedural commands, excluding the connection |
| `connection` | Borrow the underlying procedural connection handle |
| `destroy` | Destroy owned queries and disconnect, rolling back uncommitted work |

Queries returned by a Database, including forks, belong to it. They can be
destroyed early; destroying the Database also destroys remaining queries. The
borrowed connection handle must not be closed independently while the Database
is in use.

## Query

`::tpersist::oo::Query new statement` creates an independent offline query.
The caller owns it and must call `destroy`. Use `Database query` to attach a
dictionary to a live connection with automatic ownership.

| Method | Meaning |
|---|---|
| `where`, `having`, `order_by`, `group_by`, `returning`, `limit`, `offset`, `distinct`, `values`, `join`, `clear` | Corresponding procedural builder arguments, excluding the statement |
| `fork` | Independent query with the current statement and same connection/owner |
| `statement` | Current native Tcl dictionary for inspection or procedural interoperability |
| `compile ?options...?` | Compile, using the attached connection's dialect by default or SQLite when offline |
| `execute ?options...?` | Execute on the attached connection; full result dictionary |
| `all ?options...?` | Execute and return only the list of row dictionaries |
| `foreach_row variable ?options...? script` | Process rows in the caller's scope |
| `destroy` | Release this wrapper |

Offline queries support construction, branching, and compilation. To execute one,
use `db_execute $connection [$query statement]` or wrap its dictionary through a
Database. A failed composition leaves the prior statement unchanged. All driver,
NULL, typing, dialect, and transaction behavior comes from the procedural layer.

See [the complete example](../examples/06_optional_oo.tcl).
