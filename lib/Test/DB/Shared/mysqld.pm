package Test::DB::Shared::mysqld;

use Moose;
use Log::Any qw/$log/;

use DBI;

use JSON;
use Test::mysqld;

use File::Slurp;
use File::Spec;
use File::Flock::Tiny;

use POSIX qw(SIGTERM WNOHANG);

# Settings
has 'test_namespace' => ( is => 'ro', isa => 'Str', default => 'test_db_shared' );

# Public facing stuff
has 'dsn' => ( is => 'ro', isa => 'Str', lazy_build => 1 );


# Internal cuisine

has '_lock_file' => ( is => 'ro', isa => 'Str', lazy_build => 1 );
has '_mysqld_file' => ( is => 'ro', isa => 'Str', lazy_build => 1 );

sub _build__lock_file{
    my ($self) = @_;
    return File::Spec->catfile( File::Spec->tmpdir() , $self->_namespace().'.lock' ).'';
}
sub _build__mysqld_file{
    my ($self) = @_;
    return File::Spec->catfile( File::Spec->tmpdir() , $self->_namespace().'.mysqld' ).'';
}

has '_testmysqld_args' => ( is => 'ro', isa => 'HashRef', required => 1);
has '_temp_db_name' => ( is => 'ro', isa => 'Str', lazy_build => 1 );
has '_shared_mysqld' => ( is => 'ro', isa => 'HashRef', lazy_build => 1 );
has '_instance_pid' => ( is => 'ro', isa => 'Int', required => 1);
has '_holds_mysqld' => ( is => 'rw', isa => 'Bool', default => 0);

around BUILDARGS => sub {
    my ($orig, $class, @rest ) = @_;

    my $hash_args = $class->$orig(@rest);
    my $test_namespace = delete $hash_args->{test_namespace};
    return {
        _testmysqld_args => $hash_args,
        _instance_pid => $$,
        ( $test_namespace ? ( test_namespace => $test_namespace ) : () ),
    }
};

sub _namespace{
    my ($self) = @_;
    return 'tdbs49C7_'.$self->test_namespace()
}

# Build a temp DB name according to this pid.
# Note it only works because the instance of the DB will run locally.
sub _build__temp_db_name{
    my ($self) = @_;
    return $self->_namespace().( $self + 0 );
}

sub _build__shared_mysqld{
    my ($self) = @_;
    # Two cases here.
    # Either the test mysqld is there and we returned the already built dsn

    # Or it's not there and we need to build it IN A MUTEX way.
    # For a start, let's assume it's not there
    return $self->_monitor(sub{
                               my $saved_mysqld;
                               if( ! -e $self->_mysqld_file() ){
                                   $log->info("PID $$ Creating new Test::mysqld instance");
                                   my $mysqld = Test::mysqld->new( %{$self->_testmysqld_args()} ) or confess
                                       $Test::mysqld::errstr;
                                   $log->trace("PID $$ Saving all $mysqld public properties");

                                   $saved_mysqld = {};
                                   foreach my $property ( 'dsn', 'pid' ){
                                       $saved_mysqld->{$property} = $mysqld->$property().''
                                   }
                                   $saved_mysqld->{pid_file} = $mysqld->my_cnf()->{'pid-file'};
                                   # DO NOT LET mysql think it can manage its mysqld PID
                                   $mysqld->pid( undef );

                                   $self->_holds_mysqld( 1 );

                                   # Create the pid_registry container.
                                   $log->trace("PID $$ creating pid_registry table in instance");
                                   $self->_with_shared_dbh( $saved_mysqld->{dsn},
                                                            sub{
                                                                my ($dbh) = @_;
                                                                $dbh->do('CREATE TABLE pid_registry(pid INTEGER PRIMARY KEY NOT NULL)');
                                                            });
                                   my $json_mysqld = JSON::encode_json( $saved_mysqld );
                                   $log->trace("PID $$ Saving ".$json_mysqld );
                                   File::Slurp::write_file( $self->_mysqld_file() , {binmode => ':raw'},
                                                            $json_mysqld );
                               } else {
                                   $log->info("PID $$ file ".$self->_mysqld_file()." is there. Reusing cluster");
                                   $saved_mysqld = JSON::decode_json(
                                       File::Slurp::read_file( $self->_mysqld_file() , {binmode => ':raw'} ) );
                               }

                               $self->_with_shared_dbh( $saved_mysqld->{dsn},
                                                        sub{
                                                            my $dbh = shift;
                                                            $dbh->do('INSERT INTO pid_registry( pid ) VALUES (?)' , {} , $self->_instance_pid());
                                                        });
                               return $saved_mysqld;
                           });
}

sub _build_dsn{
    my ($self) = @_;
    if( $$ != $self->_instance_pid() ){
        confess("Do not build the dsn in a subprocess of this instance creator");
    }

    my $dsn = $self->_shared_mysqld()->{dsn};
    return $self->_with_shared_dbh( $dsn, sub{
                                        my $dbh = shift;
                                        my $temp_db_name = $self->_temp_db_name();
                                        $log->info("PID $$ creating temporary database '$temp_db_name' on $dsn");
                                        $dbh->do('CREATE DATABASE '.$temp_db_name);
                                        $dsn =~ s/dbname=([^;])+/dbname=$temp_db_name/;
                                        $log->info("PID $$ local dsn is '$dsn'");
                                        return $dsn;
                                    });
}


sub _teardown{
    my ($self) = @_;
    my $dsn = $self->_shared_mysqld()->{dsn};
    $self->_with_shared_dbh( $dsn,
                             sub{
                                 my $dbh = shift;
                                 $dbh->do('DELETE FROM pid_registry WHERE pid = ?',{}, $self->_instance_pid());
                                 my ( $count_row ) = $dbh->selectrow_array('SELECT COUNT(*) FROM pid_registry');
                                 if( $count_row ){
                                     $log->info("PID $$ Some PIDs are still registered as using this DB. Not tearing down");
                                     return;
                                 }
                                 $log->info("PID $$ no pids anymore in the DB. Tearing down");
                                 $log->info("PID $$ unlinking ".$self->_mysqld_file());
                                 unlink $self->_mysqld_file();
                                 $log->info("PID $$ terminating mysqld instance (sending SIGTERM to ".$self->pid().")");
                                 kill SIGTERM, $self->pid();
                             });
}

sub DEMOLISH{
    my ($self) = @_;
    if( $$ != $self->_instance_pid() ){
        # Do NOT let subprocesses that forked
        # after the creation of this to have an impact.
        return;
    }

    $self->_monitor(sub{
                        # We always want to drop the local process database.
                        my $dsn = $self->_shared_mysqld()->{dsn};
                        $self->_with_shared_dbh($dsn, sub{
                                                    my $dbh = shift;
                                                    my $temp_db_name = $self->_temp_db_name();
                                                    $log->info("PID $$ dropping temporary database $temp_db_name");
                                                    $dbh->do("DROP DATABASE ".$temp_db_name);
                                                });
                        $self->_teardown();
                    });

    if( $self->_holds_mysqld() ){
        # This is the mysqld holder process. Need to wait for it
        # before exiting
        $log->info("PID $$ mysqld holder process waiting for mysqld termination");
        while( waitpid( $self->pid() , 0 ) <= 0 ){
            $log->info("PID $$ db pid = ".$self->pid()." not down yet. Waiting 2 seconds");
            sleep(2);
        }
        my $pid_file = $self->_shared_mysqld()->{pid_file};
        $log->trace("PID $$ unlinking mysql pidfile $pid_file. Just in case");
        unlink( $pid_file );
        $log->info("PID $$ Ok, mysqld is gone");
    }
}

=head2 pid

See L<Test::mysqld>

=cut

sub pid{
    my ($self) = @_;
    return $self->_shared_mysqld()->{pid};
}

sub _monitor{
    my ($self, $sub) = @_;
    $log->trace("PID $$ locking file ".$self->_lock_file());
    my $lock = File::Flock::Tiny->lock( $self->_lock_file() );
    return $sub->();
}

sub _with_shared_dbh{
    my ($self, $dsn, $code) = @_;
    my $dbh = DBI->connect_cached( $dsn, 'root', '' , { RaiseError => 1 });
    return $code->($dbh);
}

__PACKAGE__->meta->make_immutable();
