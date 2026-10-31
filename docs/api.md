# API reference

```tcl
package require tpersist 0.1
namespace import ::tpersist::db_*
```

Importing is optional. Every public command is also available with its full
`::tpersist::db_` name. Import into an application namespace or import individual
commands when appropriate. Connections are opaque handles passed as arguments;
there are no public instance commands.

## Statements and expressions

Statements and expression nodes are native Tcl dictionaries. Every builder
returns a new value; the input value remains reusable. There is no statement
destructor and no connection is needed to build or compile a statement.

| Command | Result |
|---|---|
| `db_select table ?-columns columnList?` or `db_select table -expr text` | SELECT, with `*` as the default projection |
| `db_insert table` | INSERT; no assignments means a default-values insert |
| `db_update table` | UPDATE; requires assignments before compilation |
| `db_delete table` | DELETE |
| `db_table name ?-schema schema? ?-as alias?` | Table reference |
| `db_col name ?-table qualifier?` | Column reference |
| `db_star ?table?` | Wildcard projection |
| `db_value value ?-type type?` | Bound literal value |
| `db_param name ?-type type?` | Named parameter supplied when compiling or executing |
| `db_null` | SQL NULL expression |
| `db_expr text` | Parse one SQL-style expression into the same dictionary nodes |

A statement's `table` argument accepts a table name, a `db_table` reference, or
a `db_define_table` definition. SELECT projection lists accept column names or
expression nodes. Use separate schema/table components and table qualifiers;
`db_col a.b` is the single identifier `"a.b"`, not `"a"."b"`.

All expression operands below must be expression nodes. Ordinary strings never
become raw SQL. Constructors may defer detailed validation to compilation.

| Commands | Arguments |
|---|---|
| `db_eq`, `db_ne`, `db_lt`, `db_le`, `db_gt`, `db_ge`, `db_like` | `left right` |
| `db_add`, `db_sub`, `db_mul`, `db_div` | `left right` |
| `db_and`, `db_or` | `expression ?expression ...?` |
| `db_not`, `db_is_null`, `db_is_not_null` | `expression` |
| `db_in`, `db_not_in` | `expression expressionList` |
| `db_asc`, `db_desc` | `expression` (ORDER BY only) |
| `db_alias` | `expression name` (projection only) |
| `db_count` | `?expression?` (defaults to `*`) |
| `db_sum`, `db_avg`, `db_min`, `db_max` | `expression` |

`db_in` takes a list of expressions, not one bound list. Empty IN compiles to
false and empty NOT IN to true. SQL's normal three-valued NULL logic applies;
use `db_is_null`, not `db_eq ... [db_null]`.

## Expression strings

`db_expr` parses one expression into ordinary builder dictionaries. An explicit
`-expr` option parses strings directly in statement commands:

```tcl
set query [db_select users -expr {id, name, age + 1 AS next_age}]
set query [db_where $query -expr {age >= :minimum AND active = TRUE}]
set query [db_order_by $query -expr {age DESC, name ASC}]
set result [db_execute $connection $query -params {minimum 18}]
```

| Form | Parsed context |
|---|---|
| `db_where statement -expr text` | One predicate |
| `db_having statement -expr text` | One predicate |
| `db_join statement table -expr text ?-type inner\|left?` | One ON predicate |
| `db_select table -expr text` | Comma-separated projections, including `AS` aliases and `*` |
| `db_returning statement -expr text` | Comma-separated returned projections |
| `db_order_by statement -expr text` | Comma-separated expressions, optionally followed by `ASC` or `DESC` |
| `db_group_by statement -expr text` | Comma-separated grouping expressions |

These forms have the same additive behavior as their dictionary counterparts.
Choose either `-expr` or the existing arguments within one call; subsequent calls
can freely mix both interfaces. `db_select -expr` replaces the `-columns` option
for that call. The optional OO layer forwards the same options, for example
`$adults where -expr {age >= 18}`.

Supported syntax includes `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, arithmetic
`+ - * /`, unary signs, parentheses, `AND`, `OR`, `NOT`, `LIKE`, `NOT LIKE`,
`IN`, `NOT IN`, `IS NULL`, and `IS NOT NULL`. Functions are limited to `COUNT`,
`SUM`, `AVG`, `MIN`, and `MAX`; `COUNT(*)` is supported. Empty IN lists follow
the builder's true/false rules. Aliases require explicit `AS`.

Precedence, from strongest to weakest, is unary signs, multiplication/division,
addition/subtraction, comparisons/IN/LIKE/IS NULL, NOT, AND, OR. Arithmetic of
the same precedence associates left. Parentheses override precedence. Chained
comparisons such as `a < b < c` are rejected; write `a < b AND b < c`.

Keywords and function names are case-insensitive; identifier and parameter names
retain their spelling. Unquoted identifiers and parameter names use ASCII letters
or underscore followed by letters, digits, or underscores. Quote identifiers
containing spaces, Unicode, or reserved words with double quotes or backticks.
Double the enclosing quote inside an identifier. Qualified columns use
`table.column`; schema qualification is still configured through `db_table`.

Single quotes delimit text values, with `''` representing a literal quote.
Backslashes are literal characters, not SQL escape sequences. Integer literals
use decimal notation even with leading zeroes and must fit signed 64-bit values.
Fractional and exponent literals retain their exact text and use the `decimal`
parameter type. TRUE/FALSE use `boolean`. Named `:parameters` use `auto`; use
`db_param -type` in the builder interface when an explicit parameter type is
needed. NULL becomes the existing NULL expression.

Literals are bound parameters, never inserted as raw SQL. Use Tcl braces around
expression strings to avoid Tcl substitution before the command runs, and pass
application data through `:parameters`. The parser never evaluates Tcl or SQL.
It rejects comments, semicolons, full statements, unsupported functions, and
syntax outside this subset. Parse errors have an `-errorcode` of
`TPERSIST PARSE position` and report a one-based Tcl character position.
Nesting and generated tree depth are bounded to protect the native stack.

For assignments, continue using dictionaries, optionally with parsed values:

```tcl
set update [db_values [db_update users] \
    [dict create age [db_expr {age + 1}]] -expressions]
```

Standalone `db_expr` accepts a single expression, including an optional alias or
sort direction for later use in an appropriate context. It does not accept a
comma-separated list; projection/order/group commands handle those lists through
`-expr`. Without `-expr`, existing strings remain literal column names or the
existing dictionary arguments, with no implicit parsing.

## Additive composition

| Command | Behavior |
|---|---|
| `db_where statement predicate` | Appends with AND; SELECT, UPDATE, DELETE |
| `db_having statement predicate` | Appends with AND; SELECT |
| `db_order_by statement expression ?expression ...?` | Appends sort expressions; SELECT |
| `db_group_by statement expression ?expression ...?` | Appends grouping expressions; SELECT |
| `db_join statement table predicate ?-type inner\|left?` | Appends a join; SELECT |
| `db_limit statement count` | Replaces limit; nonnegative signed 64-bit integer |
| `db_offset statement count` | Replaces offset; nonnegative signed 64-bit integer |
| `db_distinct statement boolean` | Sets DISTINCT; SELECT |
| `db_values statement dictionary ?-expressions?` | Merges assignments; INSERT, UPDATE |
| `db_returning statement expression ?expression ...?` | Appends projections; INSERT, UPDATE, DELETE |
| `db_clear statement clause` | Removes a clause |

ORDER BY, GROUP BY, and RETURNING also accept column names as shorthand for
`db_col`. For `db_values`, dictionary values are ordinary bound data by default.
With `-expressions`, every value must be an expression node:

```tcl
set insert [db_values [db_insert users] {name Alice age 30}]
set update [db_values [db_update users] [dict create \
    age [db_add [db_col age] [db_value 1 -type integer]] \
    note [db_null]] -expressions]
```

Repeated assignment keys replace their earlier values. Supported `db_clear`
clauses are `where`, `having`, `order_by`, `group_by`, `returning`, `limit`,
`offset`, `distinct`, `values`, and `joins`. Removing a filter from UPDATE or
DELETE allows all rows to be affected, following ordinary SQL semantics.

## Compilation and parameters

```tcl
db_compile statement ?-dialect sqlite|postgresql|mysql? ?-params dictionary? ?-nulls names?
```

SQLite is the default dialect. Compilation returns:

| Key | Meaning |
|---|---|
| `sql` | Dialect SQL with TDBC named placeholders such as `:p1` |
| `params` | Placeholder-to-value dictionary for TDBC |
| `types` | Placeholder-to-type dictionary, including unbound/NULL parameters |
| `required` | Names of parameters that still need values |
| `dialect` | Dialect used to compile |

Parameter names are logical application names; generated placeholders are an
implementation detail. Repeated occurrences of a named parameter share a binding
and must declare the same type. Unused bindings and bindings listed in both
`-params` and `-nulls` are errors. Compilation can leave named parameters
unresolved for inspection; execution requires all of them to be supplied.

`-nulls` explicitly binds named parameters to SQL NULL. They are omitted from
the final TDBC value dictionary. Missing application parameters are errors, so
they cannot silently become NULL. No caller variables are used as bindings.

Supported value types are `auto` (default), `text`, `integer`, `bigint`, `real`,
`double`, `boolean`, `binary`, `decimal`, `date`, and `timestamp`.

- `auto` passes the native Tcl value to TDBC without guessing a type from its
  spelling. Use an explicit type when the distinction matters.
- `integer` and `bigint` validate the signed 64-bit range. The database column
  can impose a narrower range.
- `real` and `double` require finite floating-point values.
- `text` keeps strings such as `00123` as text. `binary` uses Tcl byte arrays.
- `decimal`, `date`, and `timestamp` are passed as text with TDBC type hints;
  the backend validates their formats. SQLite does not guarantee exact DECIMAL
  storage under numeric affinity; use TEXT when exact decimal text is required.

Identifiers are quoted separately from values. This API deliberately has no
raw SQL expression constructor. Dialect differences include quoting, pagination,
empty INSERT syntax, schema types, generated keys, and RETURNING availability.

## Connections and results

```tcl
db_connect -database app.sqlite ?-autobegin boolean? ?driverOptions...?
db_connect -dialect postgresql -database app ?driverOptions...?
db_connect -dialect mysql -database app ?driverOptions...?
db_disconnect connection
db_execute connection statement ?-params dictionary? ?-nulls names?
db_foreach_row connection rowVariable statement ?-params dictionary? ?-nulls names? script
```

The driver packages are `tdbc::sqlite3`, `tdbc::postgres`, and `tdbc::mysql`.
They are loaded on connection creation. Build-time database libraries are not
required by tpersist. Driver options such as `-host`, `-port`, `-user`,
`-password`, `-timeout`, and `-isolation` are forwarded; support depends on the
driver. `-password` is translated to MySQL's `-passwd`. SQLite requires a
filename or `:memory:` and enables foreign-key enforcement on connection.

Execution always uses the connection's dialect. Handles belong to one
interpreter and must not be shared between interpreters or threads. Closing a
connection rolls back uncommitted work. TDBC objects are also cleaned up when
their interpreter is deleted.

`db_execute` returns a dictionary with:

- `columns`: ordered names reported by the driver.
- `rows`: a list of dictionaries keyed by column name.
- `rowcount`: affected-row count for writes when the driver knows it, otherwise
  `-1`. SELECT always returns `-1`; use `llength` on `rows` for fetched rows.

SQL NULL has no key in a row dictionary. Empty strings retain their keys with
an empty value. Duplicate reported column names raise an error; give projections
unique names with `db_alias`.

`db_foreach_row` assigns each row in the caller's scope and returns the number
of rows visited, including a row whose body invokes `break`. It supports Tcl
`break`, `continue`, `return`, and errors, and closes results/statements on every
exit. It avoids building another result list in tpersist; underlying TDBC drivers
may buffer all rows themselves.

The SQLite TDBC driver may report no column names for a query returning no rows.
In that case `columns` is empty, while `rows {}` still represents a successful
empty query. Older SQLite driver combinations use a Unicode replacement character
as a NULL sentinel; use a recent SQLite Tcl/TDBC combination for lossless text
containing that character. These are driver limitations, not JSON conversions.

## Transactions

```tcl
db_begin connection
db_commit connection
db_rollback connection
db_transaction connection script
db_savepoint connection name
db_rollback_to connection name
db_release connection name
```

By default, statement execution starts a transaction if none is active. Reads
also start one. Commit or roll back explicitly, or use `db_transaction` to make
the scope explicit. `-autobegin 0` retains the driver's normal behavior outside
an explicitly managed transaction.

`db_transaction` runs the script in the caller's scope. A successful completion,
plain `return`, `break`, or `continue` commits. Errors and nonstandard return
codes roll back. `return -code error` is also a failure and rolls back. Commit
errors trigger rollback attempts, preserving the original error information.

If a transaction is already active, `db_transaction` creates a savepoint and
commits/releases only that nested scope. It does not commit the surrounding
transaction. Explicit savepoints must be released or rolled back in reverse
creation order. Rolling back to a savepoint leaves it active until release.
Do not manually commit/roll back the enclosing connection inside a managed
`db_transaction` body.

Schema commands do not start automatic transactions. They participate in an
existing transaction on SQLite and PostgreSQL. MySQL schema commands reject an
active transaction because DDL can commit implicitly. MySQL tables created by
tpersist use InnoDB; transactional behavior of pre-existing tables still depends
on their storage engine.

## Schema definitions

```tcl
db_define_table name columnDictionary ?-schema schema? ?-primary_key names? ?-unique columnLists? ?-foreign_keys definitions?
db_schema_sql definition ?-dialect sqlite|postgresql|mysql?
db_create_table connection definition ?-if_not_exists boolean?
db_drop_table connection table ?-if_exists boolean?
db_create_index connection name table columns ?-unique boolean? ?-if_not_exists boolean?
```

Each column specification is a dictionary with required `type`. Supported schema
types are `integer`, `bigint`, `real`, `double`, `text`, `varchar`, `blob`,
`binary`, `boolean`, `decimal`, `date`, and `timestamp`.

Optional fields are `primary_key`, `not_null`, `unique`, `auto_increment`,
`default`, `length`, `precision`, and `scale`. Flags are booleans. VARCHAR requires
a positive `length`. DECIMAL accepts precision 1–65 and a scale no greater than
precision. Defaults must be literal `db_value` or `db_null` expressions; binary
defaults and arbitrary default SQL are not supported. Defaults are compiled as
escaped SQL literals because DDL cannot generally bind them.

`auto_increment` requires a single integer primary key with no default. SQLite
requires the exact type `integer`; PostgreSQL uses an identity column and MySQL
uses AUTO_INCREMENT. Composite primary keys may be declared with multiple column
flags or the table's `-primary_key`, but not both forms together.

`-unique` is a list of column-name lists. Each foreign-key definition has
`columns`, `table`, and `referenced_columns`, plus optional `on_delete` and
`on_update` actions: `cascade`, `restrict`, `no action`, `set null`, or
`set default`. MySQL rejects `set default`. MySQL also rejects
`db_create_index ... -if_not_exists 1`.

## Dictionary format and errors

A minimal statement looks like:

```tcl
version 1 kind select table {node table name users} columns {{node col name id}}
```

Optional keys correspond to clauses: `where`, `having`, `joins`, `order_by`,
`group_by`, `limit`, `offset`, `distinct`, `values`, and `returning`. Predicate
and expression clauses contain lists of expression dictionaries. `values` maps
column names to expression dictionaries. A join has `table`, `on`, and `type`.
`db_define_table` returns a separate versioned dictionary with kind `table_def`.

Use builders for normal code; dictionaries can also be inspected and edited with
Tcl's `dict` commands. Compilation validates required fields, unknown or
inapplicable fields, node shapes, supported clauses, types, and a maximum
expression nesting depth of 100. Recompiling an edited value always revalidates
it; no hidden compiled cache can become stale.

Extension errors use an `-errorcode` beginning with `TPERSIST`, followed by a
category such as `VALIDATION`, `TYPE`, `PARAMETER`, `DIALECT`, `UNSUPPORTED`,
`CONNECTION`, or `TRANSACTION`. Tcl argument/type parser errors may retain their
native codes. Database errors retain the driver's error code and SQLSTATE when
provided; some driver errors use `NONE`.

This release has no ORM tracking, relationship loading, migration generation,
connection pool, raw SQL API, CTEs, window functions, subqueries, upserts, or
table aliases on write statements. RETURNING requires SQLite 3.35+ or PostgreSQL
and is rejected for MySQL. Backend capabilities and type semantics remain those
of the actual database and installed TDBC driver.
