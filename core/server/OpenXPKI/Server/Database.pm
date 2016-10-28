package OpenXPKI::Server::Database;
use Moose;
use utf8;
=head1 Name

OpenXPKI::Server::Database - Handles database connections and encapsulates DB
specific drivers/functions.

=cut

use OpenXPKI::Debug;
use OpenXPKI::Exception;
use OpenXPKI::Server::Database::DriverRole;
use OpenXPKI::Server::Database::QueryBuilder;
use OpenXPKI::Server::Database::Query;
use DBIx::Handler;
use DBI::Const::GetInfoType; # provides %GetInfoType hash
use Math::BigInt;
use MooseX::Params::Validate;
use SQL::Abstract::More;

## TODO special handling for SQLite databases from OpenXPKI::Server::Init->get_dbi()
# if ($params{TYPE} eq "SQLite") {
#     if (defined $args->{PURPOSE} && ($args->{PURPOSE} ne "")) {
#         $params{NAME} .= "._" . $args->{PURPOSE} . "_";
#         ##! 16: 'SQLite, name: ' . $params{NAME}
#     }
# }

################################################################################
# Attributes
#

has 'log' => (
    is => 'ro',
    isa => 'Object',
    required => 1,
);

# Parameters to construct DSN
has 'db_params' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
);

has 'driver' => (
    is => 'ro',
    does => 'OpenXPKI::Server::Database::DriverRole',
    lazy => 1,
    builder => '_build_driver',
);

has 'query_builder' => (
    is => 'ro',
    isa => 'OpenXPKI::Server::Database::QueryBuilder',
    lazy => 1,
    default => sub {
        my $self = shift;
        return OpenXPKI::Server::Database::QueryBuilder->new(
            sqlam => $self->sqlam,
            $self->driver->namespace ? (namespace => $self->driver->namespace) : (),
        );
    },
);

has 'sqlam' => ( # SQL query builder
    is => 'rw',
    isa => 'SQL::Abstract::More',
    lazy => 1,
    default => sub {
        my $self = shift;
        return SQL::Abstract::More->new(%{$self->driver->sqlam_params});
    },
    # TODO Support Oracle 12c LIMIT syntax: OFFSET 4 ROWS FETCH NEXT 4 ROWS ONLY
    # TODO Support LIMIT for other DBs by giving a custom sub to "limit_offset"
);

has 'db_version' => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    default => sub {
        my $self = shift;
        return $self->dbh->get_info($GetInfoType{SQL_DBMS_VER});
    },
);

has '_dbix_handler' => (
    is => 'rw',
    isa => 'DBIx::Handler',
    lazy => 1,
    builder => '_build_dbix_handler',
    handles => {
        start_txn => 'txn_begin',
        commit => 'txn_commit',
        rollback => 'txn_rollback',
    },
    predicate => '_dbix_handler_initialized', # for test cases
);

################################################################################
# Builders
#

sub _build_driver {
    my $self = shift;
    my %args = %{$self->db_params}; # copy hash

    my $driver = $args{type};
    OpenXPKI::Exception->throw (
        message => "Parameter 'type' missing: it must equal the last part of a package in the OpenXPKI::Server::Database::Driver::* namespace.",
    ) unless $driver;
    delete $args{type};

    my $class = "OpenXPKI::Server::Database::Driver::".$driver;

    eval { use Module::Load; autoload($class) };
    OpenXPKI::Exception->throw (
        message => "Unable to require() database driver package",
        params => { class_name => $class, message => $@ }
    ) if $@;

    my $instance;
    eval { $instance = $class->new(%args) };
    OpenXPKI::Exception->throw (
        message => "Unable to instantiate database driver class",
        params => { class_name => $class, message => $@ }
    ) if $@;

    OpenXPKI::Exception->throw (
        message => "Database driver class does not seem to be a Moose class",
        params => { class_name => $class }
    ) unless $instance->can('does');

    OpenXPKI::Exception->throw (
        message => "Database driver class does not consume role OpenXPKI::Server::Database::DriverRole",
        params => { class_name => $class }
    ) unless $instance->does('OpenXPKI::Server::Database::DriverRole');

    return $instance;
}

sub _build_dbix_handler {
    my $self = shift;
    ##! 4: "DSN: ".$self->_dsn
    ##! 4: "User: ".$self->user
    ##! 4: "Additional connect() attributes: " . join " | ", map { $_." = ".$self->dbi_connect_attrs->{$_} } keys %{$self->dbi_connect_attrs}
    return DBIx::Handler->new(
        $self->driver->dbi_dsn,
        $self->driver->user,
        $self->driver->passwd,
        {
            RaiseError => 1,
            AutoCommit => 0,
            %{$self->driver->dbi_connect_params},
        }
    );
}

################################################################################
# Methods
#

sub dbh {
    my $self = shift;
    # If this is too slow due to DB pings, we could pass "no_ping" attribute to
    # DBIx::Handler and copy the "fixup" code from DBIx::Connector::_fixup_run()
    my $dbh = $self->_dbix_handler->dbh;     # fork safe DBI handle
    $dbh->{FetchHashKeyName} = 'NAME_lc';    # enforce lowercase names
    return $dbh;
}

# Execute given query
sub run {
    my $self = shift;
    my ($query) = pos_validated_list(\@_,
        { isa => 'OpenXPKI::Server::Database::Query' },
    );
    ##! 2: "Query: " . $query->string;
    my $sth = $self->dbh->prepare($query->string);
    # bind parameters via SQL::Abstract::More to do some magic
    $self->sqlam->bind_params($sth, @{$query->params});
    $sth->execute;
    return $sth;
}

# SELECT
# Returns: DBI statement handle
sub select {
    my $self = shift;
    my $query = $self->query_builder->select(@_);
    return $self->run($query);
}

# SELECT - return first row
# Returns: DBI statement handle
sub select_one {
    my $self = shift;
    my $sth = $self->select(@_);
    return $sth->fetchrow_hashref;
}

# INSERT
# Returns: DBI statement handle
sub insert {
    my $self = shift;
    my $query = $self->query_builder->insert(@_);
    return $self->run($query);
}

# UPDATE
# Returns: DBI statement handle
sub update {
    my $self = shift;
    my $query = $self->query_builder->update(@_);
    return $self->run($query);
}

# Create a new insert ID ("serial")
sub next_id {
    my ($self, $table) = @_;

    # get new serial number from DBMS (sql sequence or special table)
    my $id_int = $self->driver->next_id(
        dbi => $self,
        table => $table,
    );
    my $id = Math::BigInt->new($id_int);
    ##! 16: 'new serial no.: ' . $id->bstr()

    # shift bitwise left and add server id (default: 255)
    my $nodeid_bits = $self->db_params->{server_shift} // 8;
    my $nodeid      = $self->db_params->{server_id} // 2 ** $nodeid_bits - 1;
    $id->blsft($nodeid_bits);
    $id->bior(Math::BigInt->new($nodeid));

    return $id->bstr();
}

__PACKAGE__->meta->make_immutable;

=head1 Description

This class contains the API to interact with the configured OpenXPKI database.

While OpenXPKI supports several database types out of the box it still allows
you to include new DBMS specific drivers without the need to change existing
code. This can be achieved by:

=over

=item 1. Writing a driver class in the C<OpenXPKI::Server::Database::Driver::*>
namespace that consumes the Moose role L<OpenXPKI::Server::Database::DriverRole>

=item 2. Referencing this class in your config.

=back

For a short example see L<OpenXPKI::Server::Database::DriverRole/Synopsis>.

=head2 Class structure

=cut

# The diagram was drawn using http://asciiflow.com

=pod

    +-------------+
    | *::Database |
    +--+-+-+------+
       | | |
       | | |  +---------------------------+
       | | +--> *::Database::DriverRole   |
       | |    +---------------------------+
       | |
       | |    +---------------------------+
       | +----> *::Database::QueryBuilder +---+
       |      +---------------------------+   |
       |                                      |
       |      +---------------------------+   |
       +------> *::Database::Query        <---+
              +---------------------------+

=head1 Attributes

=head2 Constructor parameters

=over

=item * B<log> - Log object (I<OpenXPKI::Server::Log>, required)

=item * B<db_params> - I<HashRef> with parameters for the DBI data source name
string.

Required keys in this hash:

=over

=item * B<type> - last part of a package in the C<OpenXPKI::Server::Database::Driver::*> namespace. (I<Str>, required)

=item * Any of the L<OpenXPKI::Server::Database::DriverRole/Constructor parameters>

=item * Additional parameters required by the specific driver

=back

=back

=head2 Others

=over

=item * B<driver> - database specific driver instance (consumer of L<OpenXPKI::Server::Database::DriverRole>)

=item * B<query_builder> - OpenXPKI query builder to create abstract SQL queries (L<OpenXPKI::Server::Database::QueryBuilder>)

Usage:

    my $query = $db->query_builder->select(
        from => 'certificate',
        columns  => [ 'identifier' ],
        where => { pki_realm => 'ca-one' },
    );
    # returns an OpenXPKI::Server::Database::Query object

=item * B<db_version> - database version, equals the result of C<$dbh-E<gt>get_version(...)> (I<Str>)

=item * B<sqlam> - low level SQL query builder (internal work horse, an instance of L<SQL::Abstract::More>)

=back

=head1 Methods

=head2 new

Constructor.

Named parameters: see L<attributes section above|/"Constructor parameters">.

=head2 select

Selects rows from the database and returns the results as a I<DBI::st> statement
handle.

Please note that C<NULL> values will be converted to Perl C<undef>.

For parameters see L<OpenXPKI::Server::Database::QueryBuilder/select>.

=head2 select_one

Selects one row from the database and returns the results as a I<HashRef>
(column name => value) by calling C<$sth-E<gt>fetchrow_hashref>.

For parameters see L<OpenXPKI::Server::Database::QueryBuilder/select>.

Returns C<undef> if the query had no results.

Please note that C<NULL> values will be converted to Perl C<undef>.

=head2 insert

Inserts the given data into the database.

For parameters see L<OpenXPKI::Server::Database::QueryBuilder/insert>.

Returns the statement handle.

Please note that Perl C<undef> will be converted to C<NULL>.

=head2 insert

Inserts rows into the database and returns the results as a I<DBI::st> statement
handle.

Please note that C<NULL> values will be converted to Perl C<undef>.

For parameters see L<OpenXPKI::Server::Database::QueryBuilder/insert>.

=head2 update

Updates rows in the database and returns the results as a I<DBI::st> statement
handle.

Please note that C<NULL> values will be converted to Perl C<undef>.

For parameters see L<OpenXPKI::Server::Database::QueryBuilder/update>.

=head2 start_txn

Starts a new transaction via C<$dbh-E<gt>begin_work>.

Transactions can be virtually nested, i.e. code with C<start_txn> and C<commit>
can later be surrounded by another pair of these functions. The result is that
only the outermost method calls will have any (database) effect.

In other words: if this method is called again before any rollback or commit
then:

=over

=item 1. the nesting level counter will be increased

=item 2. B<no> action will be performed on the database

=back

=head2 commit

Commits a transaction.

If currently in a nested transaction, decreases the nesting level counter.

croaks if there was a rollback in a nested transaction.

=head2 rollback

Rolls back a transaction.

If currently in a nested transaction, notes the rollback for later and decreases
the nesting level counter.

=cut

################################################################################

=head1 Low level methods

The following methods allow more fine grained control over the query processing.

=head2 dbh

Returns a fork safe DBI handle.

To remain fork safe DO NOT CACHE this (also do not convert into a lazy attribute).

=head2 run

Executes the given query and returns a DBI statement handle.

    my $sth = $db->run($query) or die "Error executing query: $@";

Parameters:

=over

=item * B<$query> - query to run (I<OpenXPKI::Server::Database::Query>)

=back

=cut
