# vi:ft=perl
#
# postgres_rewrite turns what the database did into a status code, which is
# what makes this module usable as a REST layer without anything in front of
# it: no rows is a 404, an insert is a 201, an update that touched nothing is
# a 204.
#
# A status with an "=" in front of it keeps the body; without it the body is
# dropped, because that is what a status like 204 or 304 requires.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: no rows is a 404
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 99";
        postgres_rewrite no_rows 404;
        postgres_output text;
    }
--- request
GET /t
--- error_code: 404



=== TEST 2: rows is a 206, and the body goes with it
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 1";
        postgres_rewrite rows =206;
        postgres_output text;
    }
--- request
GET /t
--- error_code: 206
--- response_body chop
bob



=== TEST 3: the same without the equals sign, so no body
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 1";
        postgres_rewrite rows 204;
        postgres_output text;
    }
--- request
GET /t
--- error_code: 204
--- response_body



=== TEST 4: an insert is a 201
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "insert into scratch (name) values ('three')";
        postgres_rewrite changes 201;
        postgres_output none;
    }
--- request
GET /t
--- error_code: 201



=== TEST 5: an update that touched nothing is a 204
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "update scratch set name = 'x' where id = -1";
        postgres_rewrite no_changes 204;
        postgres_output none;
    }
--- request
GET /t
--- error_code: 204



=== TEST 6: a rewrite for one method only
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 1";
        postgres_rewrite POST rows 201;
        postgres_output text;
    }
--- request
GET /t
--- error_code: 200
--- response_body chop
bob



=== TEST 7: the same location, now with the method it was meant for
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 1";
        postgres_rewrite POST rows 201;
        postgres_output text;
    }
--- request
POST /t
--- error_code: 201



=== TEST 8: two conditions, and only one of them holds
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select name from cats where id = 99";
        postgres_rewrite no_rows 410;
        postgres_rewrite rows 206;
        postgres_output text;
    }
--- request
GET /t
--- error_code: 410



=== TEST 9: "errors" is about a column, not about the query failing
# This condition looks for a column whose name starts with "error" and has
# a value in the first row.  It is meant for a stored procedure that reports
# its own trouble in the result set rather than by raising; a query that
# the database refuses never gets this far and answers 500, which
# t/errors.t covers.
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 'not allowed' as error";
        postgres_rewrite errors 403;
        postgres_output none;
    }
--- request
GET /t
--- error_code: 403



=== TEST 10: an error column that is NULL is not an error
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select null::text as error, 1 as ok";
        postgres_rewrite errors 403;
        postgres_output text;
    }
--- request
GET /t
--- error_code: 200



=== TEST 11: no error column at all
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select answer from single";
        postgres_rewrite no_errors 202;
        postgres_output none;
    }
--- request
GET /t
--- error_code: 202



=== TEST 12: an error column keeps no_errors from firing
--- http_config
    upstream pg {
        postgres_server 127.0.0.1:15432 dbname=ngxtest user=postgres;
    }
--- config
    location = /t {
        postgres_pass pg;
        postgres_query "select 'not allowed' as error";
        postgres_rewrite no_errors 202;
        postgres_output none;
    }
--- request
GET /t
--- error_code: 200
