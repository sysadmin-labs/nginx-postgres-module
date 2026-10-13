# Changelog

Newest first.  Dates are release dates.

## 1.0.0 (2026-10-13)

### Fixed

- **`postgres_output hex` wrote past the end of its buffer.**  It takes the
  buffer at half the length of the value and then writes one byte per pair
  of characters *including a half pair at the end*, so any value of odd
  length that does not start with `\x` -- `select 'abc'` is enough -- put
  one byte into the request pool past where it was allowed to.  The length
  is computed from what is actually decoded now, an odd number of characters
  is refused as not being a hex string, and the check that would have said
  so in the first place is no longer commented out.

- **`postgres_output json` had the same disagreement in the other
  direction.**  The pass that counts bytes and the pass that writes them
  used different conditions: the writing pass quotes a value of no length
  whatever its type, the counting pass did not.  An `int2vector` is type 22,
  inside the range both passes treat as numeric, and it is empty whenever it
  holds no elements -- `select ''::int2vector` -- so two quotes were written
  that nobody had counted.

- `ngx_http_get_variable()` was dereferenced without checking for NULL, in
  the block that copies column names into the parent request's variables.
  It returns NULL when a variable's own `get_handler` fails or when it
  cannot allocate, and every caller in nginx checks for that.  The
  `ngx_palloc()` next to it was unchecked as well.

- A `postgres_rewrite` entry was used before it was filled in.
  `ngx_array_push()` hands back whatever was in that memory, and the
  directive sets only `key` and `status`: `location` is assigned only when
  the third argument is *not* a status code, so for every ordinary
  `postgres_rewrite <condition> <status>` it stayed as it was found.
  `ngx_postgres_rewrite()` then reads `location.len` on every match, and
  acts on a pointer from the same memory if that length looks non-zero.
  valgrind named it exactly: "Conditional jump or move depends on
  uninitialised value(s)".

  Noticed while reading that code, not changed: a third argument that is not
  a status code is silently taken as a redirect target, and `status` is then
  left at what `ngx_atoi()` returned for it.  Upstream refused such an
  argument -- the `return NGX_CONF_ERROR` is still there, commented out.

- **`postgres_escape` killed the worker on nginx 1.30.4 and later**, in the
  rewrite phase of the first request that reached a location using it, and
  with `master_process off` not even a signal was logged.

  This function builds rewrite-module codes by hand, which means it carries
  a copy of nginx's `ngx_http_rewrite_value()` -- and a copy from 2017.  Up
  to 1.30.3 and 1.31.2, `ngx_http_script_complex_value_code()` both
  allocated the buffer and left the finished value on the script engine's
  stack.  The fix for CVE-2026-42533 -- a heap buffer overflow in that
  engine, with the `map` directive and with non-cacheable variables -- split
  the two apart, and the push onto the stack moved into a new
  `ngx_http_script_complex_value_end_code` that has to be appended after the
  value is compiled.

  Without it nothing is pushed, and `ngx_postgres_escape_string()`, which
  reads `e->sp - 1`, reads and then writes one slot below the base of that
  stack.  The end code is appended now, guarded by version: the stable
  branch got it in 1.30.4, the mainline one in 1.31.3.

  The deeper problem is not fixed and is worth naming: this module mirrors
  nginx's private `ngx_http_rewrite_loc_conf_t` and reimplements one of its
  static functions.  Every nginx release can break that, and this is the
  second time it has.

- **Every request answered 502 on nginx 1.30 and later.**  That release
  brought the change "now the keepalive directive in the upstream block is
  enabled by default", and its keepalive module walks every explicit
  upstream in its `init_main_conf`: an upstream that says nothing about
  keepalive is no longer left alone, because `max_cached` arrives unset and
  that code reads unset as "use 32", not as "off".  It then replaces
  `uscf->peer.init` with its own.

  For this module that is fatal.  A connection here is not a socket, it is a
  `PGconn` with a state machine on it, and a request handed a connection out
  of nginx's cache gets a socket this module knows nothing about.  The module
  notices -- that is what `ngx_postgres_upstream_is_my_peer()` is for -- and
  answers 502 with "postgres: trying to connect to something that is not
  PostgreSQL database".

  A module's `postconfiguration` runs after every `init_main_conf`, so the
  peer is claimed back there.  nginx's keepalive cache stays allocated and
  unused, which costs a few hundred bytes per upstream and nothing else;
  this module has its own pool, `postgres_keepalive`, which knows what a
  connection here actually is.

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

- A note worth writing down, because it cost two rounds here and would cost
  anyone else the same: **a `return` in a location with a content handler
  fires in the rewrite phase**, so the handler never runs.  Ten blocks and
  two cases in `ci/pool.sh` used `return 204` to get a response with no
  body; none of them asked the database anything, and `ci/pool.sh` reported
  ten slow requests answering instantly as a pass.  `postgres_output none`
  is the way to say "no body" -- the module then answers 200 with an empty
  one.

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
