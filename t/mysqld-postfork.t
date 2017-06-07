#! perl -w

use strict;
use warnings;

use DBI;
use Test::More;
use Test::DB::Shared::mysqld;

use Log::Any::Adapter qw/Stderr/;

my @pids = ();

foreach my $i ( 1..3 ){
    my $child_pid;
    unless( $child_pid = fork() ){
        my $db_pid;
        my $testdb = Test::DB::Shared::mysqld->new(
            my_cnf => {
                'skip-networking' => '', # no TCP socket
            }
        );
        my $dbh = DBI->connect($testdb->dsn(), 'root', '', { RaiseError => 1 } );
        $dbh->ping();
        diag( "Creating table bla in ".$testdb->dsn() );
        $dbh->do('CREATE TABLE bla( foo INTEGER PRIMARY KEY NOT NULL )');
        exit(0);
    }else{
        push @pids, $child_pid;
    }
}

foreach my $pid ( @pids ){
    diag("Waiting for pid $pid");
    waitpid( $pid, 0 );
}

# ok( ! kill( 0, $db_pid ), "Ok db pid is NOT running (was teared down by the scope escape)");
ok(1);

done_testing();
