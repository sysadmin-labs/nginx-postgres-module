# vi:ft=perl
#
# What the module does when the database, the query or the configuration
# will not do what was asked.  The oracle is both halves: what the client
# sees, and what the error log says about it -- a 500 with nothing written
# down is barely better than a hang.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: a query the database refuses
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select * from no_such_table";
        postgres_output text;
    }
--- request
GET /t
--- error_code: 500
--- error_log
failed to receive result



=== TEST 2: the database is not listening
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15499 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 1";
        postgres_output value;
        postgres_connect_timeout 2s;
    }
--- request
GET /t
--- error_code: 502



=== TEST 3: a database that does not exist
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=no_such_database user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 1";
        postgres_output value;
    }
--- request
GET /t
--- error_code: 502



=== TEST 4: "value" output with more than one value
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats";
        postgres_output value;
    }
--- request
GET /t
--- error_code: 500
--- error_log
received 3 value(s) instead of expected single value



=== TEST 5: "value" output with a NULL
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 2";
        postgres_output value;
    }
--- request
GET /t
--- error_code: 500
--- error_log
received NULL value



=== TEST 6: a required field that is NULL
# "required" writes a line in the error log and leaves the variable empty.
# It does not produce a 500, which is what the documentation this module
# came with has always claimed; no version of it ever set a status here.
# And it only says anything at all when something reads the variable: the
# check lives in the variable's own get_handler, which a request that never
# looks at it never reaches.
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 2";
        postgres_output none;
        postgres_set $name 0 0 required;
        add_header X-Name "[$name]";
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Name: []
--- error_log
requires non-NULL value



=== TEST 7: a required field in a row that is not there
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 99";
        postgres_output none;
        postgres_set $name 0 0 required;
        add_header X-Name "[$name]";
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Name: []
--- error_log
out of range of the received result-set



=== TEST 8: a column that is not in the result
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats order by id";
        postgres_output none;
        postgres_set $paws 0 paws required;
        add_header X-Paws "[$paws]";
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Paws: []
--- error_log
wasn't found in the received result-set



=== TEST 9: an output format that does not exist
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 1";
        postgres_output yaml;
    }
--- must_die
--- error_log
invalid output format "yaml"



=== TEST 10: a rewrite condition that does not exist
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 1";
        postgres_rewrite sometimes 418;
    }
--- must_die



=== TEST 11: postgres_pass to an upstream that does not exist
--- config
    location = /t {
        postgres_pass no_such_upstream;
        postgres_query "select 1";
    }
--- must_die



=== TEST 12: postgres_output twice in one location
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 1";
        postgres_output text;
        postgres_output json;
    }
--- must_die
--- error_log
is duplicate



=== TEST 13: two queries for the same method
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query GET "select 1";
        postgres_query GET "select 2";
    }
--- must_die
--- error_log
is duplicate



=== TEST 14: the worker survives a query that failed
# The connection is the thing: a failed query must not take the pool with
# it, so a good query right after a bad one has to work.
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
        postgres_keepalive max=2;
    }
--- config
    location = /bad {
        postgres_pass pg;
        postgres_query "select * from no_such_table";
        postgres_output text;
    }
    location = /good {
        postgres_pass pg;
        postgres_query "select answer from single";
        postgres_output value;
    }
--- pipelined_requests eval
["GET /bad", "GET /good", "GET /bad", "GET /good"]
--- error_code eval
[500, 200, 500, 200]
--- no_error_log
[alert]
