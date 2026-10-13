# nginx-postgres-module

[![Build & Test][build-test-badge]][build-test-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![Pool][pool-badge]][pool-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/build-test.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/freebsd.yml
[pool-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/pool.yml/badge.svg
[pool-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/pool.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-postgres-module/actions/workflows/lint.yml

Talk to PostgreSQL from nginx, without anything in between.  A location
holds a query, the answer comes back as text or JSON, and what the database
did -- rows or no rows, a change or no change -- becomes the status code.

The connection is non-blocking all the way through: the module drives libpq
asynchronously inside nginx's event loop, so a worker handling a slow query
goes on serving everything else.  Connections are kept in a pool per worker
rather than opened per request.

## Directives

### postgres\_server

**syntax:** `postgres_server <ip>[:<port>] | unix:<dir> [port=<port>] [dbname=<name>] [user=<user>] [password=<pass>]`

**context:** upstream

```nginx
upstream database {
    postgres_server 127.0.0.1:5432 dbname=shop user=www password=secret;
}
```

Several `postgres_server` lines in one `upstream` block are used in turn.

### postgres\_keepalive

**syntax:** `postgres_keepalive off | max=<count> [mode=single|multi] [overflow=ignore|reject]`

**default:** `max=10 mode=single overflow=ignore`

**context:** upstream

How many connections a worker keeps open, and what happens when they are
all busy: `ignore` lets the request have a connection of its own and closes
it afterwards, `reject` answers `503`.

`mode=single` matches a pooled connection by server only, `mode=multi` also
by database and user -- which is what a configuration with several
`dbname=` or `user=` values in one upstream needs.

### postgres\_pass

**syntax:** `postgres_pass <upstream>`

**context:** location, if in location

### postgres\_query

**syntax:** `postgres_query [<methods>] <query>`

**context:** http, server, location, if in location

The query to send.  It may contain variables, and a location may hold one
query per method:

```nginx
location = /cats {
    postgres_pass database;
    postgres_query HEAD GET "select name from cats";
    postgres_query POST     "insert into cats (name) values ($name)";
    postgres_output json;
}
```

A request whose method has no query, and where a method list was given,
gets a `405`.

### postgres\_output

**syntax:** `postgres_output rds | text | value | binary_value | json | hex | none`

**default:** `rds`

**context:** http, server, location, if in location

- `text` -- every value, row by row, separated by newlines, with `(null)`
  for a NULL and no trailing newline
- `value` -- one row with one column and nothing else, or a `500`
- `binary_value` -- the same, unconverted
- `json` -- an array of objects; NULL is `null`, integers are numbers, a
  single `json` or `jsonb` column is passed through as it stands
- `hex` -- the value in hexadecimal, for a `bytea`
- `rds` -- the row-data-stream format `ngx_rds_json` and `ngx_rds_csv` read
- `none` -- nothing, for a location that only sets variables or a status

### postgres\_rewrite

**syntax:** `postgres_rewrite [<methods>] <condition> [=]<status>`

**context:** http, server, location, if in location

Turn what the database did into a status code.  An `=` in front of the
status keeps the response body; without it the body is dropped, which is
what a `204` or a `304` requires.

The conditions are `no_changes` and `changes` -- whether a statement
touched any row -- `no_rows` and `rows`, and `no_errors` and `errors`.

The last pair is not about the query failing: a query the database refuses
never reaches a rewrite and answers `500`.  They look for a column whose
name starts with `error` and has a value in the first row, which is for a
stored procedure that reports its own trouble in the result set rather than
by raising.

```nginx
location = /cats {
    postgres_pass database;
    postgres_query GET "select name from cats where id = $id";
    postgres_rewrite no_rows 404;
    postgres_output json;
}
```

### postgres\_set

**syntax:** `postgres_set $<variable> <row> <column> [optional|required]`

**context:** http, server, location

Put one field of the result into a variable.  The row is a number, the
column a number or a name.  `required` answers `500` when the field is
missing or NULL; `optional`, the default, leaves the variable empty.

### postgres\_escape

**syntax:** `postgres_escape $<escaped> [[=]$<unescaped>]`

**context:** http, server, location

Quote a value for use in a query: the result is the value with any quote
in it doubled, wrapped in single quotes, ready to be put straight into
`postgres_query`.

A value that is not there, or is empty, becomes `NULL` -- so a missing
argument gives `where name = NULL`, which matches nothing, rather than a
query that will not parse.  An `=` in front of the source variable changes
that one case: an empty value then becomes `''` instead of `NULL`.

```nginx
location = /cats {
    postgres_pass database;
    postgres_escape $name $arg_name;
    postgres_query "select id from cats where name = $name";
    postgres_output value;
}
```

### postgres\_connect\_timeout

**default:** `10s`

**context:** http, server, location

### postgres\_result\_timeout

**default:** `30s`

**context:** http, server, location

How long to wait for the result of a query.  A query that takes longer ends
the request; it does not end the query, which goes on running in the
database.

## Variables

`$postgres_columns`, `$postgres_rows`, `$postgres_affected` and
`$postgres_query` -- the shape of the result, how many rows a statement
changed, and the query that was sent.

## Building

Needs libpq and its headers: `libpq-dev` on Debian and its relatives, the
`postgresqlNN-client` port on FreeBSD.

```sh
./configure --add-module=/path/to/nginx-postgres-module
```

or as a loadable module:

```sh
./configure --with-compat --add-dynamic-module=/path/to/nginx-postgres-module
```

```nginx
load_module modules/ngx_postgres_module.so;
```

`config` asks `pg_config` where libpq is, which is the answer on any system
with a PostgreSQL client installed.  Where that is not on the path:

```sh
PG_CONFIG=/opt/pgsql/bin/pg_config ./configure --add-module=...
LIBPQ_INC=/opt/pgsql/include LIBPQ_LIB=/opt/pgsql/lib ./configure --add-module=...
```

## Testing

```sh
ci/build.sh 1.30.5 /tmp/nginx-postgres
ci/postgres.sh
TEST_NGINX_BINARY=/tmp/nginx-postgres/sbin/nginx prove -r t/
ci/pool.sh /tmp/nginx-postgres/sbin/nginx
```

`ci/postgres.sh` starts a cluster of its own in `ci-work/`, with the rows
the suite expects, and throws it away with that directory.  It does not
touch a system cluster, and it leaves an already running server on its port
alone.

`ci/pool.sh` is the one the suite cannot replace.  Test::Nginx sends a
request and waits for the answer, so the keepalive pool is never under
pressure in `t/`: a module that opened a connection per request and never
gave one back would pass every block there.  That script sends forty
requests at once through a pool of two and then asks `pg_stat_activity` how
many connections are left.

## License

BSD 2-Clause, see [LICENSE](LICENSE).
