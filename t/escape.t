# vi:ft=perl
#
# postgres_escape quotes a value for a query: the result is the value with
# every quote in it doubled and the whole thing in single quotes, ready to be
# put straight into postgres_query.
#
# Its own file, because a block here took the rest of t/sanity.t with it when
# it went wrong -- Test::Nginx stops at the first file it cannot reach the
# server for, and everything after that is reported as a failure it never
# ran.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 14: a variable in the query
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_escape $escaped $arg_id;
        postgres_query "select name from cats where id = $escaped";
        postgres_output value;
    }
--- request
GET /t?id=3
--- response_body chop
tom



=== TEST 15: postgres_escape keeps a quote out of the query
# The apostrophe goes over the wire as itself -- nginx hands $arg_* over
# still escaped, so a %27 here would reach the query as those three
# characters and prove nothing.
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_escape $escaped $arg_name;
        postgres_query "select $escaped as given";
        postgres_output value;
    }
--- request
GET /t?name=o'brien
--- response_body chop
o'brien



=== TEST 15a: an argument that is not there becomes NULL
# Not an empty string: "where name = NULL" matches nothing, which is what a
# missing argument should do, and it parses.
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_escape $escaped $arg_name;
        postgres_query "select count(*) as found from cats where name = $escaped";
        postgres_output value;
    }
--- request
GET /t
--- response_body chop
0



=== TEST 15b: an empty argument becomes NULL as well
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_escape $escaped $arg_name;
        postgres_query "select coalesce($escaped, 'was null') as given";
        postgres_output value;
    }
--- request
GET /t?name=
--- response_body chop
was null



=== TEST 15c: with an equals sign, an empty argument is an empty string
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_escape $escaped =$arg_name;
        postgres_query "select coalesce($escaped, 'was null') as given";
        postgres_output none;
        postgres_set $given 0 0 optional;
        add_header X-Given "[$given]";
    }
--- request
GET /t?name=
--- error_code: 200
--- response_headers
X-Given: []
