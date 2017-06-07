#! perl -w

use strict;
use warnings;

use Test::More;
use Test::DB::Shared::mysqld;

ok( my $testdb = Test::DB::Shared::mysqld->new() );
ok( $testdb->temp_db_name() , "ok got temp DB name");

done_testing();
