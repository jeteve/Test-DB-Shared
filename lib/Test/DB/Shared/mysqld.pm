package Test::DB::Shared::mysqld;

use Moose;
use Log::Any qw/$log/;

has 'dsn' => ( is => 'ro', isa => 'Str', lazy_build => 1 );
has 'temp_db_name' => ( is => 'ro', isa => 'Str', lazy_build => 1 );

# Build a temp DB name according to this pid.
# Note it only works because the instance of the DB will run locally.
sub _build_temp_db_name{
    my ($self) = @_;
    return 'test_db_'.$$;
}

sub _build_dsn{
    my ($self) = @_;
    my $dsn = $self->shared_dsn();
    my $dbh = DBI->connect( $self->shared_dsn(), undef, '' );
    $dbh->do('CREATE DATABASE '.$self->temp_db_name() );
    warn $dsn;
}

__PACKAGE__->meta->make_immutable();
