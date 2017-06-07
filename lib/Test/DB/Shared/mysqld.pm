package Test::DB::Shared::mysqld;

use Moose;
use Log::Any qw/$log/;

use DBI;

use JSON;
use Test::mysqld;

use File::Spec;
use File::Flock::Tiny;

use POSIX qw(SIGTERM WNOHANG);

my $LOCK_FILE = File::Spec->catfile( File::Spec->tmpdir() , 'test-db-shared.lock' );

# Public facing stuff
has 'dsn' => ( is => 'ro', isa => 'Str', lazy_build => 1 );


# Internal cuisine
has '_testmysqld_args' => ( is => 'ro', isa => 'HashRef', required => 1);
has '_temp_db_name' => ( is => 'ro', isa => 'Str', lazy_build => 1 );
has '_shared_mysqld' => ( is => 'ro', isa => 'HashRef', lazy_build => 1 );
has '_instance_pid' => ( is => 'ro', isa => 'Int', required => 1);

# Mutable args
# Note that only ONE process will have that set.
has '_mysqld' => ( is => 'rw', isa => 'Maybe[Test::mysqld]' );

around BUILDARGS => sub {
    my ($orig, $class, @rest ) = @_;

    my $hash_args = $class->$orig(@rest);
    return {
        _testmysqld_args => $hash_args,
        _instance_pid => $$
    }
};

# Build a temp DB name according to this pid.
# Note it only works because the instance of the DB will run locally.
sub _build__temp_db_name{
    my ($self) = @_;
    return 'test_db_shared_'.$$;
}

sub _build__shared_mysqld{
    my ($self) = @_;
    # Two cases here.
    # Either the test mysqld is there and we returned the already built dsn

    # Or it's not there and we need to build it IN A MUTEX way.
    # For a start, let's assume it's not there
    return $self->_monitor(sub{
                               $log->info("PID $$ Creating new Test::mysqld instance");
                               my $mysqld = Test::mysqld->new( %{$self->_testmysqld_args()} ) or confess
                                   $Test::mysqld::errstr;
                               $self->_mysqld( $mysqld );
                               $log->trace("PID $$ Saving all $mysqld public properties");
                               my $saved_mysqld = {};
                               foreach my $property ( 'dsn', 'pid' ){
                                   $saved_mysqld->{$property} = $mysqld->$property().''
                               }
                               $saved_mysqld->{pid_file} = $mysqld->my_cnf()->{'pid-file'};

                               # DO NOT LET mysql think it can manage its mysqld PID
                               $mysqld->pid( undef );

                               # Create the pid_registry container.
                               $log->trace("PID $$ creating pid_registry table in instance");
                               $self->_with_shared_dbh( $saved_mysqld->{dsn},
                                                        sub{
                                                            my ($dbh) = @_;
                                                            $dbh->do('CREATE TABLE pid_registry(pid INTEGER PRIMARY KEY NOT NULL)');
                                                        });

                               $log->trace("PID $$ Saving ".JSON::encode_json( $saved_mysqld ) );

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
    $self->_monitor(sub{
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
                                                     $log->info("PID $$ terminating mysqld instance (sending SIGTERM to ".$self->pid().")");
                                                     kill SIGTERM, $self->pid();
                                                     local $?; # waitpid may change this value :/
                                                     while (waitpid($self->pid(), 0) <= 0) {}
                                                     my $pid_file = $self->_shared_mysqld()->{pid_file};
                                                     $log->trace("PID $$ unlinking mysql pidfile $pid_file. Just in case");
                                                     unlink( $pid_file );
                                                     $log->info("PID $$ Ok, mysqld is gone");
                                                 });
                    });
}

sub DEMOLISH{
    my ($self) = @_;

    # We always want to drop the local process database.
    my $dsn = $self->_shared_mysqld()->{dsn};
    $self->_with_shared_dbh($dsn, sub{
                                my $dbh = shift;
                                my $temp_db_name = $self->_temp_db_name();
                                $log->info("PID $$ dropping temporary database $temp_db_name");
                                $dbh->do("DROP DATABASE ".$temp_db_name);
                            });
    if( $$ == $self->_instance_pid() ){
        # Original process that did register itself as a user of
        # the DB cluster.
        $self->_teardown();
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
    $log->trace("PID $$ locking file $LOCK_FILE");
    my $lock = File::Flock::Tiny->lock( $LOCK_FILE );
    return $sub->();
}

sub _with_shared_dbh{
    my ($self, $dsn, $code) = @_;
    my $dbh = DBI->connect_cached( $dsn, 'root', '' , { RaiseError => 1 });
    return $code->($dbh);
}

__PACKAGE__->meta->make_immutable();
