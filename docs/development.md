# Building and testing

The implementation uses C11, Tcl's public object API, and Tcl stubs. The C
sources implement dictionary builders, validation, and DML compilation. The Tcl
sources implement TDBC adaptation and schema definitions. CMake embeds these
scripts into the library, so shared and static builds expose the same API without
a runtime dependency on files in the source tree.

There is no direct SQLite, libpq, MySQL, or cJSON link dependency. Runtime
database access goes through the installed TDBC packages.

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
cmake --install build --prefix /your/prefix
```

Select a nondefault Tcl installation using `TCL_INCLUDE_DIR` and
`TCL_LIBRARY_DIR`, or specify `TCL_INCLUDE_PATH`, `TCL_STUB_LIBRARY`, and
`TCL_TCLSH` explicitly. Build Tcl 8.6 and Tcl 9 variants separately; the shared
library is not a cross-major-version binary. A matching `tclsh` is required for
the test runner.

```sh
cmake -S . -B build86 \
  -DTCL_INCLUDE_PATH=/usr/include/tcl8.6 \
  -DTCL_STUB_LIBRARY=/usr/lib/x86_64-linux-gnu/libtclstub8.6.a \
  -DTCL_TCLSH=/usr/bin/tclsh8.6
cmake --build build86
```

Use `-DBUILD_SHARED_LIBS=OFF` for static embedding. Link the resulting archive
with the matching Tcl runtime and call `Tpersist_Init(interp)` after Tcl
initialization. The static smoke test exercises that path. Set
`TCL_RUNTIME_LIBRARY` if discovery needs an explicit runtime-library path.

`-DTPERSIST_NAVISERVER=ON -DNAVISERVER_INCLUDE_DIR=/path/to/include` enables
NaviServer module entry points. This option requires NaviServer development
headers and an appropriate deployment environment.

## Tests

The `tcltest` suite covers:

- Reusable query branches and copy-on-write behavior.
- SQL generation for all three dialects, including quoting and pagination.
- Named and typed parameters, SQL injection strings, NULL, blobs, and integers
  beyond floating-point precision, with explicit overflow rejection on Tcl 8.6.
- Schema constraints, defaults, joins, aggregates, CRUD, and RETURNING.
- Transaction success and failures, nested savepoints, and Tcl control flow.
- Result/statement cleanup, interpreter deletion, and error propagation.
- TDBC protocol tests using test doubles, plus live database tests.

Run against an uninstalled shared build:

```sh
tclsh8.6 tests/all.tcl build86
tclsh8.6 tests/all.tcl build86 -match 'compile-*'
```

SQLite execution tests are skipped when `tdbc::sqlite3` is unavailable. Set
`TPERSIST_REQUIRE_SQLITE=1` to make missing SQLite support fail the run. Compiler,
schema, and protocol tests still run without database drivers.

PostgreSQL and MySQL tests require explicit connection options for disposable
test databases. Each test creates and drops uniquely named tables. An enabled
backend that cannot connect fails the suite instead of being silently skipped.

```sh
export TPERSIST_TEST_POSTGRESQL='-host 127.0.0.1 -port 5432 -database tpersist_test -user tester -password test_only'
export TPERSIST_TEST_MYSQL='-host 127.0.0.1 -port 3306 -database tpersist_test -user tester -password test_only'
tclsh8.6 tests/all.tcl build86
```

The GitHub Actions workflow provisions PostgreSQL 16 and MySQL 8.4 services,
installs Ubuntu's Tcl/TDBC packages, runs the full suite and examples, and checks
static embedding. Locally, only report live backend tests as passed when their
constraints were enabled.

For sanitizer builds with GCC or Clang, add
`-DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'` and the
matching shared/executable linker flags. A noninstrumented `tclsh` needs the
AddressSanitizer runtime preloaded; a statically linked smoke-test executable
gets it through the linker flags.

## Layout

| Path | Responsibility |
|---|---|
| `src/library.c` | Initialization, command registration, embedded adapter loading |
| `src/statements.c` | Value-based builders and integer conversion |
| `src/compiler.c` | Validation, expression traversal, SQL and bound parameters |
| `library/tdbc.tcl` | Connections, execution, row loops, transactions |
| `library/schema.tcl` | Table metadata, DDL compilation, schema commands |
| `library/oo.tcl` | Separate optional TclOO convenience package |
| `tests/` | Compiler, schema, protocol, SQLite and optional server integration tests |
| `examples/` | Runnable usage examples |

All C objects allocated during a command belong to a per-call arena. Returning
objects retain normal Tcl references; temporary objects are released on success
and error. State is interpreter-local, with TDBC managing database resources.
Future dialects should extend compilation and capability checks while reusing
the same statement dictionaries and TDBC execution adapter.
