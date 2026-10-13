# Changelog

Newest first.  Dates are release dates.

## Unreleased

### Fixed

- The module did not build with gcc 12 or later.  `if (pgdt->statements)`
  asks whether an array inside a structure is NULL, which it never is, and
  `-Werror=address` refuses the comparison.  Behind that one line were two
  more things:

  - **The table of prepared statements wrote past its end.**  It holds 256
    hashes per connection; the search loop leaves its index at 256 when
    nothing matched and nothing is free, and the old code then assigned to
    `statements[256]`, on top of whatever the structure keeps after it.  A
    connection that had seen 256 distinct queries was enough to trigger it.
    A query now goes out with its parameters when the table is full, which
    is what the other branch of that `if` always did -- and that branch had
    never run, because the condition could not be false.

  - **`PQprepare` leaked its result and its failures were ignored.**  Every
    statement prepared leaked a `PGresult`, and a `PQprepare` that failed
    still had its hash written into the table, after which every later
    request on that connection asked the server for a statement it does not
    have.  The result is freed, a failure is logged and not remembered, and
    the query goes out with its parameters instead.

- `postgres_output json` put a NUL byte after the closing bracket and
  counted it in `Content-Length`, so what a client received was not JSON.
  Both paths did it -- the array and the single `json` column that is passed
  through -- and it came from a pair of debugging `fprintf("%s")` calls that
  sat at the end of that function and needed a terminated string.  The
  calls were commented out; the byte they needed stayed.

### Changed

- `config` no longer pretends to detect a libpq version.  Six probes for
  9.1 through 9.6 sat at the end of it, every one guarded by
  `if [ $ngx_found = no ]` *after* the search above had already set it to
  `yes`, so none of them ever ran; the version they would have found went
  into a variable nothing reads; and the error that followed -- "unable to
  detect version of the libpq library" -- could never appear.  Every PQ
  function this module calls has been in libpq since 8.0.

- `config` asks `pg_config` before it starts guessing paths, which is the
  answer on any system with a PostgreSQL client installed, FreeBSD
  included.  The FreeBSD port carries a patch that rewrites a hardcoded
  `/usr/local` in that file with the package prefix; it does not need to any
  more.

- A loadable build puts libpq on this module's own link line rather than
  into `CORE_LIBS`, where it would be linked into every other dynamic module
  of the same build as well.

### Added

- A test suite that needs nothing but nginx, this module and a PostgreSQL.
  The one that came with the module needs `ngx_echo`, `ngx_rds_json`,
  `ngx_eval` and `ngx_form_input`: four foreign modules to ask this one a
  question, and the reason is historical -- the original answered in `rds`
  format only, and reading that needs `ngx_rds_json`.  This fork has
  `postgres_output json`, so it does not.

  49 blocks over three files: the output handlers and the variables, what
  `postgres_rewrite` does with rows, changes and errors, and what happens
  when the query, the database or the configuration will not do what was
  asked.

- `ci/postgres.sh`, which starts a cluster of its own in `ci-work/` with the
  rows the suite expects and throws it away with that directory.  It does
  not touch a system cluster and leaves an already running server on its
  port alone.  Two things make it longer than it looks: `initdb` refuses to
  run as root and the FreeBSD job does run as root, so there the cluster is
  created as the `postgres` user the server package brings; and the server
  binaries are not on the path on Debian and its relatives, where they live
  under `/usr/lib/postgresql/<version>/bin`.

- `ci/pool.sh` and a workflow of its own, for the half the suite cannot
  reach.  Test::Nginx sends a request and waits for the answer, so the
  keepalive pool is never under pressure in `t/`: a module that opened a
  connection per request and never gave one back would pass every block
  there and take a database down in production.  Forty requests arrive at
  once through a pool of two, then `pg_stat_activity` is asked how many
  connections are left, and `overflow=reject` is checked for the 503 it
  promises.

- The reload gate asks the database through the module, so a reload that
  dropped the module answers 404 and one that lost the pool answers 502.
  The pool is also why the gate matters here: it holds connections open
  across a reload, and a cycle that leaked one shows up in the master's
  descriptor count, which `ci/reload.sh` counts after every round.

- The scaffolding the other modules in this organization carry: a version
  and digest pin for every build input, the release matrix, the FreeBSD
  virtual machine, A/UBSan, valgrind, CodeQL, shellcheck and actionlint.

- A README that documents what this fork added where the old one did not.
  `json` is named in a list of the fork's features but is missing from the
  syntax line of `postgres_output` itself, and `hex` appears nowhere at all.
  `errors` and `no_errors` are described as looking for `error:` in a json
  response, which is one of two things they do: a column whose name starts
  with `error`, with a value in the first row, is the other and the usual
  one.  And neither pair is about a query that failed -- that answers 500
  and never reaches a rewrite.
