# vi:ft=perl
#
# The rows ci/postgres.sh puts in the database:
#
#     cats     (1, 'bob', 4), (2, NULL, 3), (3, 'tom', NULL)
#     single   one row, one column, 42
#     scratch  empty, and the only table anything here writes to
#
# A NULL in each nullable column is deliberate: a NULL is not an empty
# string, and every output handler has to say which one it got.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: a value
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select answer from single";
        postgres_output value;
    }
--- request
GET /t
--- response_body chop
42



=== TEST 2: a column as text, with a NULL in it
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats order by id";
        postgres_output text;
    }
--- request
GET /t
--- response_body eval
"bob\n(null)\ntom"



=== TEST 3: text output walks the rows, not the columns
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select id, name from cats order by id";
        postgres_output text;
    }
--- request
GET /t
--- response_body eval
"1\nbob\n2\n(null)\n3\ntom"



=== TEST 4: json, where a NULL is null and a number is not a string
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select id, name from cats order by id";
        postgres_output json;
    }
--- request
GET /t
--- response_body chop
[{"id":1,"name":"bob"},{"id":2,"name":null},{"id":3,"name":"tom"}]



=== TEST 5: the json body ends at the bracket
# It used to carry a NUL after it, counted in Content-Length, which left
# every JSON parser with something it could not read.
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select id from cats order by id";
        postgres_output json;
    }
--- request
GET /t
--- response_body chop
[{"id":1},{"id":2},{"id":3}]



=== TEST 6: a text value that needs escaping in json
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 'a\"b' as quoted";
        postgres_output json;
    }
--- request
GET /t
--- response_body chop
[{"quoted":"a\"b"}]



=== TEST 7: no output at all
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats";
        postgres_output none;
    }
--- request
GET /t
--- error_code: 200
--- response_body



=== TEST 8: how many rows and columns came back
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select id, name, paws from cats order by id";
        postgres_output none;
        add_header X-Rows $postgres_rows;
        add_header X-Columns $postgres_columns;
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Rows: 3
X-Columns: 3



=== TEST 9: a single field into a variable
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select id, name from cats order by id";
        postgres_output none;
        postgres_set $first_name 0 1 required;
        add_header X-Name $first_name;
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Name: bob



=== TEST 10: a field named rather than numbered
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select id, name, paws from cats order by id";
        postgres_output none;
        postgres_set $paws 0 paws required;
        add_header X-Paws $paws;
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Paws: 4



=== TEST 11: an optional field that is NULL
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 2";
        postgres_output none;
        postgres_set $name 0 0 optional;
        add_header X-Name "[$name]";
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Name: []



=== TEST 12: how many rows an update touched
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "insert into scratch (name) values ('one'), ('two')";
        postgres_output none;
        add_header X-Affected $postgres_affected;
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Affected: 2



=== TEST 13: the query that was sent
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 1 as one";
        postgres_output none;
        add_header X-Query $postgres_query;
    }
--- request
GET /t
--- error_code: 200
--- response_headers
X-Query: select 1 as one



=== TEST 16: a query per method
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query GET  "select 'read' as what";
        postgres_query POST "select 'write' as what";
        postgres_output value;
    }
--- request
POST /t
--- response_body chop
write



=== TEST 17: a method with no query of its own
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query GET "select 'read' as what";
        postgres_output value;
    }
--- request
POST /t
--- error_code: 405



=== TEST 18: the keepalive pool answers more than once
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
        postgres_keepalive max=2;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select answer from single";
        postgres_output value;
    }
--- pipelined_requests eval
["GET /t", "GET /t", "GET /t", "GET /t"]
--- response_body eval
["42", "42", "42", "42"]



=== TEST 19: no keepalive at all
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
        postgres_keepalive off;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select answer from single";
        postgres_output value;
    }
--- pipelined_requests eval
["GET /t", "GET /t"]
--- response_body eval
["42", "42"]



=== TEST 20: a column of every type the json handler has a case for
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select a_bool, a_smallint, an_integer, a_bigint, a_text, a_date, a_null from types";
        postgres_output json;
    }
--- request
GET /t
--- response_body chop
[{"a_bool":"t","a_smallint":42,"an_integer":123456,"a_bigint":1234567890123,"a_text":"text","a_date":"2026-10-13","a_null":null}]
