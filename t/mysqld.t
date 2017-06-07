#! perl -w

use strict;
use warnings;

use Test::More;
use Test::DB::Shared::mysqld;

use Log::Any::Adapter qw/Stderr/;

ok( my $testdb = Test::DB::Shared::mysqld->new(
    my_cnf => {
        'skip-networking' => '', # no TCP socket
    }
) );
ok( $testdb->dsn() , "Ok got dsn");
ok( $testdb->pid() , "Ok got SQL pid");

done_testing();
