#!/bin/sh
#
# Make sure a PostgreSQL the test suite can use is listening, and leave an
# existing one alone.
#
# usage: ci/postgres.sh
#
# It starts a cluster of its own in the work tree rather than touching a
# system one: the suite needs a known database with known rows in it, and
# the cluster is thrown away with ci-work/.  The distribution's packaged
# cluster is not used and not disturbed.
#
#     PGPORT        port to listen on, 15432 by default
#     PGDATABASE    database to create, ngxtest by default
#
# Two things make this longer than it looks.  initdb refuses to run as root,
# and the FreeBSD job does run as root -- so when that is the case the
# cluster is created and started as the "postgres" user the server package
# brings along.  And the server binaries are not on the path on Debian and
# its relatives, where they live under /usr/lib/postgresql/<version>/bin.

set -eu

PORT=${PGPORT:-15432}
DB=${PGDATABASE:-ngxtest}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/postgres
DATA=$WORK/data

# ---------------------------------------------------------- already running?

if command -v psql > /dev/null 2>&1 &&
	psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -c 'select 1' \
		> /dev/null 2>&1
then
	echo "ci/postgres.sh: a server already answers on port $PORT"
	exit 0
fi

# ------------------------------------------------------------- find the tools

find_tool() {
	tool=$1

	if command -v "$tool" > /dev/null 2>&1; then
		command -v "$tool"
		return 0
	fi

	# Newest version first, so that a machine with several installed uses
	# the newest rather than whichever sorts first.
	for dir in $(ls -d /usr/lib/postgresql/*/bin /usr/local/pgsql/bin \
		/opt/homebrew/opt/postgresql*/bin 2>/dev/null | sort -rV); do
		if [ -x "$dir/$tool" ]; then
			echo "$dir/$tool"
			return 0
		fi
	done

	return 1
}

INITDB=$(find_tool initdb) || {
	echo "ci/postgres.sh: no initdb found, and nothing answers on port $PORT" >&2
	echo "ci/postgres.sh: install a PostgreSQL server" >&2
	exit 2
}
PG_CTL=$(find_tool pg_ctl) || {
	echo "ci/postgres.sh: found initdb but no pg_ctl" >&2
	exit 2
}
PSQL=$(find_tool psql) || {
	echo "ci/postgres.sh: found initdb but no psql" >&2
	exit 2
}

echo "ci/postgres.sh: using $INITDB"

# --------------------------------------------------------------- who runs it

rm -rf "$WORK"
mkdir -p "$DATA" "$WORK/run"

if [ "$(id -u)" = 0 ]; then
	id postgres > /dev/null 2>&1 || {
		echo "ci/postgres.sh: running as root and there is no postgres user" >&2
		echo "ci/postgres.sh: initdb refuses to run as root, so one is needed" >&2
		exit 2
	}
	chown -R postgres "$WORK"
	as_postgres() {
		su -m postgres -c "$*"
	}
else
	as_postgres() {
		sh -c "$*"
	}
fi

# ------------------------------------------------------------ build and start

# No password: the cluster listens on the loopback address only and lives
# for the length of a test run.  trust also means the suite does not have to
# carry a password around in half a dozen configuration files.
as_postgres "$INITDB -D '$DATA' -U postgres -A trust --no-sync" \
	> "$WORK/initdb.log" 2>&1 || {
	tail -20 "$WORK/initdb.log" >&2
	exit 1
}

# fsync off and a tiny cluster: this holds a handful of rows for a few
# minutes and then goes away.
as_postgres "$PG_CTL -D '$DATA' -l '$WORK/server.log' -w -t 60 -o \
	\"-p $PORT -k '$WORK/run' -h 127.0.0.1 -F -N 100\" start" \
	> "$WORK/pg_ctl.log" 2>&1 || {
	cat "$WORK/pg_ctl.log" >&2
	tail -30 "$WORK/server.log" >&2 2>/dev/null || true
	exit 1
}

# ------------------------------------------------------------- the test data

"$PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
	-q <<SQL
CREATE DATABASE $DB;
SQL

"$PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -v ON_ERROR_STOP=1 \
	-q <<'SQL'
-- What the suite reads.  Three rows, and a NULL in each nullable column,
-- because a NULL is not an empty string and the output handlers have to
-- say so.
CREATE TABLE cats (
    id    integer PRIMARY KEY,
    name  text,
    paws  integer
);
INSERT INTO cats (id, name, paws) VALUES
    (1, 'bob',  4),
    (2, NULL,   3),
    (3, 'tom',  NULL);

-- What the suite writes to, so that no test has to put the rows above back.
CREATE TABLE scratch (
    id    serial PRIMARY KEY,
    name  text
);

-- One row, one column, for the "value" output handler.
CREATE TABLE single AS SELECT 42 AS answer;

-- Every type the output handlers have a case for, in one row.
CREATE TABLE types AS SELECT
    true                            AS a_bool,
    42::smallint                    AS a_smallint,
    123456::integer                 AS an_integer,
    1234567890123::bigint           AS a_bigint,
    1.5::real                       AS a_real,
    'text'::text                    AS a_text,
    'char'::char(4)                 AS a_char,
    '\x0102ff'::bytea               AS a_bytea,
    '2026-10-13'::date              AS a_date,
    NULL::text                      AS a_null;
SQL

echo "ci/postgres.sh: PostgreSQL is up on port $PORT with database $DB"
"$PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -t -c 'select version()' |
	sed -n '1s/^ */ci\/postgres.sh: /p'
