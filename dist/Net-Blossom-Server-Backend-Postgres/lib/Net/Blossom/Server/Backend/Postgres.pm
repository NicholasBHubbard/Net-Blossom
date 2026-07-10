package Net::Blossom::Server::Backend::Postgres;

use strictures 2;

use Carp qw(croak);
use Class::Tiny qw(dbh base_url _schema);
use DBI ();
use File::Temp qw(tempfile);
use Net::Blossom::BlobDescriptor;
use Net::Blossom::_URL;
use Net::Blossom::Server::BlobResult;
use Scalar::Util qw(blessed);

our $VERSION = '0.001000';

sub BUILDARGS {
    my $class = shift;
    my %args = _constructor_args(@_);
    my %known = map { $_ => 1 } qw(dsn username password dbh base_url connect_attrs);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    croak "dsn and dbh are mutually exclusive"
        if defined $args{dsn} && defined $args{dbh};
    croak "dsn or dbh is required"
        unless defined $args{dsn} || defined $args{dbh};
    croak "base_url is required"
        unless defined $args{base_url};
    croak "connect_attrs must be a hash reference"
        if defined $args{connect_attrs} && ref($args{connect_attrs}) ne 'HASH';

    my $base_url = _normalize_base_url($args{base_url});
    my $dbh = defined $args{dbh} ? _validate_dbh($args{dbh}) : _connect(%args);
    my ($schema) = $dbh->selectrow_array(q{SELECT current_schema()});
    croak "Postgres connection has no current schema"
        unless defined $schema && length $schema;

    return {
        dbh      => $dbh,
        base_url => $base_url,
        _schema  => $schema,
    };
}

sub deploy_schema {
    my ($self) = @_;
    my $dbh = $self->dbh;
    my $blobs = $self->_table('blossom_blobs');
    my $owners = $self->_table('blossom_owners');
    my $owner_index = $dbh->quote_identifier('blossom_owners_pubkey_order');

    $self->_assert_schema_compatible;

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS $blobs (
            sha256   text PRIMARY KEY NOT NULL,
            body_oid oid NOT NULL,
            size     bigint NOT NULL,
            type     text NOT NULL,
            uploaded bigint NOT NULL
        )
    });
    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS $owners (
            pubkey   text NOT NULL,
            sha256   text NOT NULL,
            type     text NOT NULL,
            uploaded bigint NOT NULL,
            PRIMARY KEY (pubkey, sha256),
            FOREIGN KEY (sha256) REFERENCES $blobs(sha256) ON DELETE CASCADE
        )
    });
    $dbh->do(qq{
        CREATE INDEX IF NOT EXISTS $owner_index
            ON $owners (pubkey, uploaded DESC, sha256 ASC)
    });

    return 1;
}

sub begin_upload {
    my ($self, %context) = @_;
    my ($fh, $path) = tempfile('net-blossom-postgres-upload-XXXXXX', TMPDIR => 1, UNLINK => 0);
    binmode $fh
        or croak "unable to binmode upload temp file: $!";

    return Net::Blossom::Server::Backend::Postgres::_Upload->new(
        storage => $self,
        fh      => $fh,
        path    => $path,
    );
}

sub get_blob {
    my ($self, $sha256) = @_;
    my $dbh = $self->_reader_dbh;
    my $blobs = $self->_table('blossom_blobs');
    my ($row, $fd);

    my $ok = eval {
        $dbh->begin_work;
        $row = $dbh->selectrow_hashref(
            qq{SELECT sha256, body_oid, size, type, uploaded FROM $blobs WHERE sha256 = ?},
            undef,
            $sha256,
        );
        $fd = $dbh->pg_lo_open($row->{body_oid}, $dbh->{pg_INV_READ})
            if defined $row;
        croak "unable to open PostgreSQL large object"
            if defined $row && !defined $fd;
        1;
    };

    if (!$ok || !defined $row) {
        my $error = $@;
        eval { $dbh->rollback unless $dbh->{AutoCommit} };
        eval { $dbh->disconnect };
        die $error unless $ok;
        return;
    }

    return Net::Blossom::Server::BlobResult->new(
        descriptor => $self->_descriptor($row),
        body       => Net::Blossom::Server::Backend::Postgres::_Stream->new(
            dbh => $dbh,
            fd  => $fd,
        ),
    );
}

sub head_blob {
    my ($self, $sha256) = @_;
    my $blobs = $self->_table('blossom_blobs');
    my $row = $self->dbh->selectrow_hashref(
        qq{SELECT sha256, size, type, uploaded FROM $blobs WHERE sha256 = ?},
        undef,
        $sha256,
    );
    return unless defined $row;
    return $self->_descriptor($row);
}

sub delete_blob {
    my ($self, $sha256, %opts) = @_;
    my $blobs = $self->_table('blossom_blobs');
    my $owners = $self->_table('blossom_owners');

    return $self->_with_transaction(sub {
        $self->_lock_blob($sha256);

        if (defined $opts{pubkey}) {
            my $rows = $self->dbh->do(
                qq{DELETE FROM $owners WHERE sha256 = ? AND pubkey = ?},
                undef,
                $sha256,
                $opts{pubkey},
            );
            return 0 unless _changed_rows($rows);
            $self->_delete_blob_if_unowned($sha256);
            return 1;
        }

        my ($exists) = $self->dbh->selectrow_array(
            qq{SELECT body_oid FROM $blobs WHERE sha256 = ?},
            undef,
            $sha256,
        );
        return 0 unless defined $exists;

        $self->dbh->do(qq{DELETE FROM $owners WHERE sha256 = ?}, undef, $sha256);
        $self->_unlink_body($exists);
        $self->dbh->do(qq{DELETE FROM $blobs WHERE sha256 = ?}, undef, $sha256);
        return 1;
    });
}

sub list_blobs {
    my ($self, $pubkey, %opts) = @_;
    my $blobs = $self->_table('blossom_blobs');
    my $owners = $self->_table('blossom_owners');
    my @where = ('o.pubkey = ?');
    my @bind = ($pubkey);

    if (defined $opts{cursor}) {
        my $cursor = $self->dbh->selectrow_hashref(
            qq{SELECT sha256, uploaded FROM $owners WHERE pubkey = ? AND sha256 = ?},
            undef,
            $pubkey,
            $opts{cursor},
        );
        return [] unless defined $cursor;
        push @where, q{(o.uploaded < ? OR (o.uploaded = ? AND o.sha256 > ?))};
        push @bind, $cursor->{uploaded}, $cursor->{uploaded}, $cursor->{sha256};
    }

    my $sql = qq{
        SELECT o.sha256, b.size, o.type, o.uploaded
          FROM $owners o
          JOIN $blobs b ON b.sha256 = o.sha256
         WHERE
    } . join(' AND ', @where) . q{
         ORDER BY o.uploaded DESC, o.sha256 ASC
    };

    if (defined $opts{limit}) {
        return [] if $opts{limit} <= 0;
        $sql .= q{ LIMIT ?};
        push @bind, int($opts{limit});
    }

    my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    return [map { $self->_descriptor($_) } @$rows];
}

sub _commit_upload {
    my ($self, $upload, %metadata) = @_;
    my $blobs = $self->_table('blossom_blobs');
    my $owners = $self->_table('blossom_owners');
    $upload->_close;
    my $created;

    $self->_with_transaction(sub {
        $self->_lock_blob($metadata{sha256});

        my ($exists) = $self->dbh->selectrow_array(
            qq{SELECT body_oid FROM $blobs WHERE sha256 = ?},
            undef,
            $metadata{sha256},
        );

        if (defined $exists) {
            $created = 0;
        }
        else {
            my $body_oid = $self->dbh->pg_lo_import($upload->_path);
            croak "unable to import PostgreSQL large object"
                unless defined $body_oid;

            my $rows = $self->dbh->do(
                qq{
                    INSERT INTO $blobs
                        (sha256, body_oid, size, type, uploaded)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (sha256) DO NOTHING
                },
                undef,
                $metadata{sha256},
                $body_oid,
                $metadata{size},
                $metadata{type},
                $metadata{uploaded},
            );
            $created = _changed_rows($rows) ? 1 : 0;
            $self->_unlink_body($body_oid) unless $created;
        }

        if (defined $metadata{pubkey}) {
            $self->dbh->do(
                qq{
                    INSERT INTO $owners
                        (pubkey, sha256, type, uploaded)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (pubkey, sha256)
                    DO UPDATE SET type = EXCLUDED.type,
                                  uploaded = EXCLUDED.uploaded
                },
                undef,
                $metadata{pubkey},
                $metadata{sha256},
                $metadata{type},
                $metadata{uploaded},
            );
        }

        return 1;
    });

    eval { $upload->_cleanup };

    return {
        descriptor => $self->_descriptor(\%metadata),
        created    => $created,
    };
}

sub _delete_blob_if_unowned {
    my ($self, $sha256) = @_;
    my $blobs = $self->_table('blossom_blobs');
    my $owners_table = $self->_table('blossom_owners');
    my ($owner_count) = $self->dbh->selectrow_array(
        qq{SELECT COUNT(*) FROM $owners_table WHERE sha256 = ?},
        undef,
        $sha256,
    );
    return if $owner_count;

    my ($body_oid) = $self->dbh->selectrow_array(
        qq{SELECT body_oid FROM $blobs WHERE sha256 = ?},
        undef,
        $sha256,
    );
    return unless defined $body_oid;

    $self->_unlink_body($body_oid);
    $self->dbh->do(qq{DELETE FROM $blobs WHERE sha256 = ?}, undef, $sha256);
    return;
}

sub _unlink_body {
    my ($self, $body_oid) = @_;
    my $unlinked = $self->dbh->pg_lo_unlink($body_oid);
    croak "unable to unlink PostgreSQL large object"
        unless $unlinked;
    return 1;
}

sub _lock_blob {
    my ($self, $sha256) = @_;
    my @keys = map {
        my $key = unpack 'N', pack 'H8', substr($sha256, $_, 8);
        $key -= 4_294_967_296 if $key > 2_147_483_647;
        $key;
    } (0, 8);

    $self->dbh->selectrow_array(
        q{SELECT pg_advisory_xact_lock(?, ?)},
        undef,
        @keys,
    );
    return;
}

sub _descriptor {
    my ($self, $row) = @_;

    return Net::Blossom::BlobDescriptor->new(
        url      => $self->base_url . '/' . $row->{sha256},
        sha256   => $row->{sha256},
        size     => 0 + $row->{size},
        type     => $row->{type},
        uploaded => 0 + $row->{uploaded},
    );
}

sub _assert_schema_compatible {
    my ($self) = @_;
    my $schema = $self->_schema;
    my $columns = $self->dbh->selectall_arrayref(q{
        SELECT column_name, udt_name
          FROM information_schema.columns
         WHERE table_schema = ?
           AND table_name = 'blossom_blobs'
    }, undef, $schema);
    return 1 unless @$columns;

    my %columns = map { $_->[0] => $_->[1] } @$columns;
    croak "incompatible blossom_blobs schema; recreate it for PostgreSQL large-object storage"
        unless !exists $columns{body}
        && defined $columns{body_oid}
        && $columns{body_oid} eq 'oid';
    return 1;
}

sub _reader_dbh {
    my ($self) = @_;
    my $dbh = $self->dbh->clone({
        AutoCommit     => 1,
        RaiseError     => 1,
        PrintError     => 0,
        pg_enable_utf8 => 0,
    });
    croak "unable to clone Postgres DBI handle for blob stream"
        unless defined $dbh;
    return $dbh;
}

sub _with_transaction {
    my ($self, $code) = @_;
    my $dbh = $self->dbh;
    my $wantarray = wantarray;
    my (@result, $result);

    croak "dbh must have AutoCommit enabled"
        unless $dbh->{AutoCommit};
    $dbh->begin_work;
    my $ok = eval {
        if ($wantarray) {
            @result = $code->();
        }
        else {
            $result = $code->();
        }
        1;
    };
    my $error = $@;

    if (!$ok) {
        eval { $dbh->rollback };
        die $error;
    }

    $dbh->commit;
    return $wantarray ? @result : $result;
}

sub _table {
    my ($self, $name) = @_;
    return $self->dbh->quote_identifier($self->_schema, $name);
}

sub _connect {
    my %args = @_;
    my $dsn = $args{dsn};
    croak "dsn must be a scalar" if ref($dsn);
    croak "dsn is required" unless length $dsn;
    croak "username must be a scalar" if defined $args{username} && ref($args{username});
    croak "password must be a scalar" if defined $args{password} && ref($args{password});

    eval 'use DBD::Pg (); 1'
        or die $@;

    my %attrs = (
        %{ $args{connect_attrs} || {} },
        AutoCommit    => 1,
        RaiseError    => 1,
        PrintError    => 0,
        pg_enable_utf8 => 0,
    );

    return DBI->connect(
        $dsn,
        $args{username},
        $args{password},
        \%attrs,
    );
}

sub _validate_dbh {
    my ($dbh) = @_;
    croak "dbh must be a DBI database handle"
        unless blessed($dbh) && $dbh->can('do') && $dbh->can('selectrow_array');
    my $driver = eval { $dbh->{Driver}{Name} };
    croak "dbh must be a Postgres DBI handle"
        unless defined $driver && $driver eq 'Pg';
    croak "dbh must have AutoCommit enabled"
        unless $dbh->{AutoCommit};
    $dbh->{RaiseError} = 1;
    $dbh->{PrintError} = 0;
    eval { $dbh->{pg_enable_utf8} = 0 };
    return $dbh;
}

sub _normalize_base_url {
    my ($base_url) = @_;
    croak "base_url must be a scalar" if ref($base_url);
    croak "base_url is required" unless length $base_url;

    croak "base_url must be a valid HTTP base URL"
        unless Net::Blossom::_URL::http_base_url($base_url);

    $base_url =~ s{/+\z}{};
    return $base_url;
}

sub _changed_rows {
    my ($rows) = @_;
    return defined $rows && $rows ne '0E0' && $rows > 0;
}

sub _constructor_args {
    return %{$_[0]} if @_ == 1 && ref($_[0]) eq 'HASH';
    croak "constructor arguments must be name/value pairs" if @_ % 2;
    return @_;
}

{
    package Net::Blossom::Server::Backend::Postgres::_Upload;

    use strictures 2;

    use Carp qw(croak);
    use Class::Tiny qw(storage fh path), {
        committed => 0,
        aborted   => 0,
    };

    sub BUILD {
        my ($self) = @_;
        $self->committed;
        $self->aborted;
        return;
    }

    sub write {
        my ($self, $chunk) = @_;
        croak "upload is already committed" if $self->{committed};
        croak "upload is aborted" if $self->{aborted};
        print {$self->{fh}} $chunk
            or croak "storage write failed: $!";
        return length $chunk;
    }

    sub commit {
        my ($self, %metadata) = @_;
        croak "upload is already committed" if $self->{committed};
        croak "upload is aborted" if $self->{aborted};

        my $result = $self->{storage}->_commit_upload($self, %metadata);
        $self->{committed} = 1;
        return $result;
    }

    sub abort {
        my ($self) = @_;
        return 1 if $self->{aborted} || $self->{committed};
        $self->{aborted} = 1;
        $self->_cleanup;
        return 1;
    }

    sub _path {
        my ($self) = @_;
        return $self->{path};
    }

    sub _cleanup {
        my ($self) = @_;
        $self->_close;
        unlink $self->{path}
            or croak "unable to remove upload temp file: $!"
            if defined $self->{path} && -e $self->{path};
        $self->{path} = undef;
        return 1;
    }

    sub _close {
        my ($self) = @_;
        return 1 unless defined $self->{fh};
        close $self->{fh}
            or croak "unable to close upload temp file: $!";
        $self->{fh} = undef;
        return 1;
    }

    sub DEMOLISH {
        my ($self) = @_;
        return if $self->{committed} || $self->{aborted};
        eval { $self->abort };
        return;
    }
}

{
    package Net::Blossom::Server::Backend::Postgres::_Stream;

    use strictures 2;

    use Carp qw(croak);
    use Class::Tiny qw(dbh fd), {
        closed => 0,
        eof    => 0,
    };

    my $READ_SIZE = 65536;

    sub BUILD {
        my ($self) = @_;
        $self->closed;
        $self->eof;
        return;
    }

    sub read {
        my ($self, undef, $length) = @_;
        if ($self->{eof}) {
            $_[1] = '';
            return 0;
        }
        croak "stream is closed" if $self->{closed};
        croak "read length must be a non-negative integer"
            unless defined $length && !ref($length) && $length =~ /\A[0-9]+\z/;

        if ($length == 0) {
            $_[1] = '';
            return 0;
        }

        my $chunk = '';
        my $read;
        my $ok = eval {
            $read = $self->{dbh}->pg_lo_read($self->{fd}, $chunk, $length);
            croak "PostgreSQL large-object read failed" unless defined $read;
            1;
        };
        if (!$ok) {
            my $error = $@;
            eval { $self->_finish(0) };
            die $error;
        }

        $_[1] = $chunk;
        if ($read == 0) {
            $self->{eof} = 1;
            $self->_finish(1);
        }
        return $read;
    }

    sub getline {
        my ($self) = @_;
        my $chunk = '';
        my $read = $self->read($chunk, $READ_SIZE);
        return if $read == 0;
        return $chunk;
    }

    sub close {
        my ($self) = @_;
        return 1 if $self->{closed};
        return $self->_finish(1);
    }

    sub _finish {
        my ($self, $commit) = @_;
        return 1 if $self->{closed};
        $self->{closed} = 1;

        my @errors;
        my $object_closed = eval {
            $self->{dbh}->pg_lo_close($self->{fd})
                or die "unable to close PostgreSQL large object\n";
            1;
        };
        push @errors, $@ unless $object_closed;

        if ($commit && $object_closed) {
            my $committed = eval { $self->{dbh}->commit; 1 };
            if (!$committed) {
                push @errors, $@;
                eval { $self->{dbh}->rollback };
                push @errors, $@ if $@;
            }
        }
        else {
            eval { $self->{dbh}->rollback };
            push @errors, $@ if $@;
        }

        eval { $self->{dbh}->disconnect };
        push @errors, $@ if $@;

        die $errors[0] if @errors;
        return 1;
    }

    sub DEMOLISH {
        my ($self) = @_;
        eval { $self->_finish(0) } unless $self->{closed};
        return;
    }
}

1;

=pod

=head1 NAME

Net::Blossom::Server::Backend::Postgres - Postgres storage backend for Blossom servers

=head1 SYNOPSIS

    use Net::Blossom::Server;
    use Net::Blossom::Server::Backend::Postgres;

    my $storage = Net::Blossom::Server::Backend::Postgres->new(
        dsn      => 'dbi:Pg:dbname=blossom;host=/var/run/postgresql',
        username => 'blossom',
        password => $password,
        base_url => 'https://cdn.example.com',
    );
    $storage->deploy_schema;

    my $server = Net::Blossom::Server->new(storage => $storage);

=head1 DESCRIPTION

C<Net::Blossom::Server::Backend::Postgres> is a Postgres storage backend for
L<Net::Blossom::Server>. It stores Blossom blob bytes and metadata in Postgres
and implements the L<Net::Blossom::Server::Storage> contract.

Postgres access is provided through L<DBI> and L<DBD::Pg>.

Blob bodies are stored as
L<PostgreSQL large objects|https://www.postgresql.org/docs/current/largeobjects.html>.
Uploads are written to a temporary file and imported only after the server has
validated the hash. Downloads are returned as streams, so blob bodies are not
loaded into Perl memory as a whole.

Each active download uses a cloned DBI connection and a read transaction until
the body reaches EOF or is closed. Deployments must allow enough PostgreSQL
connections for their concurrent downloads. Very large public media services
may still prefer a backend that stores blob bytes outside the metadata database.

This backend serializes uploads and deletes for the same hash with a
transaction-level PostgreSQL advisory lock. The lock is released when the
transaction commits or rolls back. Direct SQL writes to the backend tables do
not participate in this locking protocol. Operations for different hashes may
run concurrently.

=head1 CONSTRUCTOR

=head2 new

    my $storage = Net::Blossom::Server::Backend::Postgres->new(
        dsn      => $dsn,
        username => $username,
        password => $password,
        base_url => $url,
    );

Creates a storage object. C<dsn> is a DBI Postgres data source string.
C<username> and C<password> are optional and are passed to C<DBI-E<gt>connect>.
C<base_url> is the public HTTP or HTTPS URL prefix used when descriptors are
created. It may include a path prefix, but not userinfo, query, or fragment
parts. Trailing slashes are removed.

Instead of C<dsn>, callers may pass an existing DBI handle as C<dbh>. The handle
must be a Postgres handle with C<AutoCommit> enabled so the backend can manage
its transactions. The backend clones this handle for each active blob download.

The backend uses the connection's current schema at construction time. All
later operations, including cloned download connections, remain bound to that
schema.

Optional C<connect_attrs> may be supplied with C<dsn>. The backend always forces
C<AutoCommit>, C<RaiseError>, C<PrintError>, and C<pg_enable_utf8> to values
needed by the storage implementation.

=head1 METHODS

=head2 dbh

    my $dbh = $storage->dbh;

Returns the DBI handle used by the backend.

=head2 base_url

    my $url = $storage->base_url;

Returns the normalized descriptor URL prefix.

=head2 deploy_schema

    $storage->deploy_schema;

Creates the required Postgres tables and indexes if they do not already exist.
They are created in the schema captured by C<new>. This method is safe to call
more than once. It does not migrate the obsolete pre-release C<bytea> schema;
recreate that schema if it is detected.

=head2 begin_upload

    my $upload = $storage->begin_upload(%context);

Starts a blob upload and returns an upload writer. The server core writes bytes
to a temporary file and later calls C<commit> with validated blob metadata. A
new blob is imported as a PostgreSQL large object transactionally.

=head2 get_blob

    my $result = $storage->get_blob($sha256);

Returns a L<Net::Blossom::Server::BlobResult> for C<$sha256>, or C<undef> when
the blob is absent. Its body is a stream backed by a dedicated DBI connection.
Reading to EOF or calling C<close> releases that connection.

=head2 head_blob

    my $descriptor = $storage->head_blob($sha256);

Returns a L<Net::Blossom::BlobDescriptor> without returning the blob body, or
C<undef> when the blob is absent.

=head2 delete_blob

    my $deleted = $storage->delete_blob($sha256, pubkey => $pubkey);

Deletes one owner relationship when C<pubkey> is supplied. The blob bytes are
deleted with C<pg_lo_unlink> when the final owner is removed. Without C<pubkey>,
the blob and all owners are deleted.

=head2 list_blobs

    my $descriptors = $storage->list_blobs($pubkey, limit => 100);

Returns descriptors owned by C<$pubkey>, sorted by C<uploaded> descending and
C<sha256> ascending. C<cursor> and C<limit> follow the
L<Net::Blossom::Server::Storage> contract.

=head1 SEE ALSO

L<PostgreSQL large objects|https://www.postgresql.org/docs/current/largeobjects.html>,
L<DBD::Pg/Large Objects>

=head1 INTERNAL METHODS

=head2 BUILDARGS

Normalizes constructor arguments for Class::Tiny.

=cut
