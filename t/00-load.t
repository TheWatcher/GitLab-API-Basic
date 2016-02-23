#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'GitLab::API::Basic' ) || print "Bail out!\n";
    use_ok( 'GitLab::API::Utils' ) || print "Bail out!\n";
}

diag( "Testing GitLab::API::Basic $GitLab::API::VERSION, Perl $], $^X" );
