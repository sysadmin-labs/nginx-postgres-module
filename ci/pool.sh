#!/bin/sh
#
# Put many requests through the keepalive pool at once and count what is
# left behind.
#
# t/ asks one question at a time -- Test::Nginx sends a request and waits --
# so the pool is never under pressure there: a module that opened a fresh
# connection per request and never returned one to the pool would pass every
# block in t/ and bring a database down in production.  This script is the
# one that looks at the pool.
#
# usage: ci/pool.sh <nginx binary>
#
# Needs the database ci/postgres.sh sets up, and psql to ask it how many
# connections it is holding.
#
# Set POOL_LOAD_MODULE to the path of ngx_postgres_module.so to test a
# loadable build.

set -eu

NGINX=${1:?path to the nginx binary missing}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/pool
PORT=${POOL_PORT:-18540}
PGPORT=${PGPORT:-15432}
DB=${PGDATABASE:-ngxtest}
MAX=2

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

PSQL=$(command -v psql 2>/dev/null) || true
if [ -z "$PSQL" ]; then
	for dir in $(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -rV); do
		[ -x "$dir/psql" ] && PSQL=$dir/psql && break
	done
fi
[ -n "$PSQL" ] || { echo "psql(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/out" "$WORK/tmp"

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

backend_connections() {
	"$PSQL" -h 127.0.0.1 -p "$PGPORT" -U postgres -d "$DB" -t -A \
		-c "select count(*) from pg_stat_activity
		    where datname = '$DB' and application_name <> 'psql'" 2>/dev/null |
		tr -d ' '
}

# --------------------------------------------------------------- the nginx

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

ngx_load=
if [ -n "${POOL_LOAD_MODULE:-}" ]; then
	ngx_load="load_module $POOL_LOAD_MODULE;"
fi

cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_load
$ngx_user
daemon on;
master_process on;
worker_processes 1;
pid $WORK/logs/nginx.pid;
error_log $WORK/logs/error.log info;
events { worker_connections 256; }
http {
    access_log off;
    client_body_temp_path $WORK/tmp/cb;
    fastcgi_temp_path $WORK/tmp/fc;
    uwsgi_temp_path $WORK/tmp/uw;
    scgi_temp_path $WORK/tmp/sc;
    default_type text/plain;

    upstream pool {
        postgres_server 127.0.0.1:$PGPORT dbname=$DB user=postgres;
        postgres_keepalive max=$MAX;
    }

    upstream rejecting {
        postgres_server 127.0.0.1:$PGPORT dbname=$DB user=postgres;
        postgres_keepalive max=$MAX overflow=reject;
    }

    server {
        listen 127.0.0.1:$PORT;

        location = /value {
            postgres_pass pool;
            postgres_query "select answer from single";
            postgres_output value;
        }

        location = /slow {
            postgres_pass pool;
            postgres_query "select pg_sleep(1), 'slept' as what";
            postgres_output none;
            return 204;
        }

        location = /reject {
            postgres_pass rejecting;
            postgres_query "select pg_sleep(1), 'slept' as what";
            postgres_output none;
            return 204;
        }

        location = /alive {
            return 200 'alive';
        }
    }
}
EOF

"$NGINX" -t -c "$WORK/conf/nginx.conf" -p "$WORK" > "$WORK/out/t.log" 2>&1 ||
	{ cat "$WORK/out/t.log"; exit 1; }
"$NGINX" -c "$WORK/conf/nginx.conf" -p "$WORK"

cleanup() {
	[ -f "$WORK/logs/nginx.pid" ] &&
		kill -QUIT "$(cat "$WORK/logs/nginx.pid")" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 1

before=$(backend_connections)
echo "--- the database holds $before connections before anything happens ---"

# ---------------------------------------------------------------- the cases

echo "--- forty requests at once, all through a pool of $MAX ---"
i=0
while [ "$i" -lt 40 ]; do
	curl -s --max-time 20 "http://127.0.0.1:$PORT/value" \
		-o "$WORK/out/v$i.txt" -w '%{http_code}\n' >> "$WORK/out/codes.txt" &
	i=$((i + 1))
done
wait

bad=$(grep -cv '^200$' "$WORK/out/codes.txt" || true)
wrong=0
i=0
while [ "$i" -lt 40 ]; do
	[ "$(cat "$WORK/out/v$i.txt" 2>/dev/null)" = 42 ] || wrong=$((wrong + 1))
	i=$((i + 1))
done

if [ "$bad" -eq 0 ] && [ "$wrong" -eq 0 ]; then
	echo "  forty answers, all 200, all 42"
else
	note "$bad requests were not 200 and $wrong bodies were not 42"
	sort "$WORK/out/codes.txt" | uniq -c | sed 's/^/  /' >&2
fi

echo "--- what the pool left behind ---"
sleep 2
after=$(backend_connections)
# A pool of MAX may hold MAX connections, and one more may be on its way
# out.  Anything beyond that means connections are being opened and not
# given back, which is the failure this script exists for.
limit=$((before + MAX + 1))
if [ "${after:-99}" -le "$limit" ]; then
	echo "  $after connections, at most $limit allowed with max=$MAX"
else
	note "$after connections left after forty requests, more than $limit"
	"$PSQL" -h 127.0.0.1 -p "$PGPORT" -U postgres -d "$DB" -c \
		"select pid, state, query from pg_stat_activity where datname = '$DB'" >&2 || true
fi

echo "--- ten slow requests at once, pool of $MAX, overflow allowed ---"
: > "$WORK/out/slow.txt"
i=0
while [ "$i" -lt 10 ]; do
	curl -s --max-time 30 -o /dev/null -w '%{http_code}\n' \
		"http://127.0.0.1:$PORT/slow" >> "$WORK/out/slow.txt" &
	i=$((i + 1))
done
wait

if [ "$(grep -c '^204$' "$WORK/out/slow.txt" || true)" -eq 10 ]; then
	echo "  all ten answered 204; overflow=ignore means they wait rather than fail"
else
	note "the slow requests did not all answer 204"
	sort "$WORK/out/slow.txt" | uniq -c | sed 's/^/  /' >&2
fi

echo "--- the same against an upstream with overflow=reject ---"
: > "$WORK/out/reject.txt"
i=0
while [ "$i" -lt 10 ]; do
	curl -s --max-time 30 -o /dev/null -w '%{http_code}\n' \
		"http://127.0.0.1:$PORT/reject" >> "$WORK/out/reject.txt" &
	i=$((i + 1))
done
wait

ok=$(grep -c '^204$' "$WORK/out/reject.txt" || true)
rejected=$(grep -c '^503$' "$WORK/out/reject.txt" || true)
if [ "$((ok + rejected))" -eq 10 ] && [ "$rejected" -gt 0 ]; then
	echo "  $ok answered, $rejected rejected with 503, which is what reject means"
else
	note "expected some 503s and nothing else: $ok answered, $rejected rejected"
	sort "$WORK/out/reject.txt" | uniq -c | sed 's/^/  /' >&2
fi

echo "--- and the pool is back to where it started ---"
sleep 3
final=$(backend_connections)
if [ "${final:-99}" -le "$limit" ]; then
	echo "  $final connections"
else
	note "$final connections left at the end, more than $limit"
fi

echo "--- the worker is still there ---"
alive=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/alive" || true)
if [ "$alive" = alive ]; then
	echo "  it answers"
else
	note "the worker did not answer after all that"
fi

echo "--- nothing in the error log that should not be there ---"
if grep -E '\[alert\]|\[emerg\]|exited on signal' "$WORK/logs/error.log"; then
	note "the log carries an alert, an emerg or a worker that died"
else
	echo "  no alert, no emerg, no signal"
fi

# A failure here is about what the module did under load, and the error log
# is where it said so.  Printing it only on a failure keeps a good run quiet.
if [ "$fail" -ne 0 ]; then
	echo >&2
	echo "--- the error log, last 40 lines ---" >&2
	tail -40 "$WORK/logs/error.log" >&2 2>/dev/null || true
	echo >&2
	echo "--- what the module said, counted ---" >&2
	sed -n 's/.*\[error\][^:]*: //p' "$WORK/logs/error.log" 2>/dev/null |
		sed 's/[0-9][0-9]*/N/g' | sort | uniq -c | sort -rn | head -10 >&2
fi

exit $fail
