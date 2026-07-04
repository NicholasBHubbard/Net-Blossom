package Net::Blossom::Server;

use strictures 2;

use Net::Blossom ();
use Net::Blossom::BlobDescriptor;
use Net::Blossom::_ConstructorArgs ();
use Net::Blossom::Server::Request;
use Net::Blossom::Server::Response;
use Net::Blossom::Server::Storage;
use Net::Blossom::Server::UploadResult;

use Carp qw(croak);
use Class::Tiny qw(storage chunk_size clock);
use Digest::SHA ();
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

my $HEX64 = qr/\A[0-9a-f]{64}\z/;

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(storage chunk_size clock);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    Net::Blossom::Server::Storage->assert_implements($args{storage});

    $args{chunk_size} = 65536 unless defined $args{chunk_size};
    croak "chunk_size must be a positive integer"
        unless !ref($args{chunk_size}) && $args{chunk_size} =~ /\A[1-9][0-9]*\z/;

    $args{clock} = sub { time } unless defined $args{clock};
    croak "clock must be a code reference" unless ref($args{clock}) eq 'CODE';

    return bless \%args, $class;
}

sub receive_blob {
    my $self = shift;
    my ($body, %opts) = @_;
    my %known = map { $_ => 1 } qw(type expected_sha256 content_length uploaded pubkey);
    my @unknown = grep { !exists $known{$_} } keys %opts;
    croak "unknown option(s): " . join(', ', sort @unknown) if @unknown;

    croak "body is required" unless defined $body;
    _validate_body($body);

    my $type = defined $opts{type} ? $opts{type} : 'application/octet-stream';
    croak "type must be a scalar" if ref($type);
    croak "type is required" unless length $type;

    if (defined $opts{expected_sha256}) {
        croak "expected_sha256 must be 64-char lowercase hex"
            unless !ref($opts{expected_sha256}) && $opts{expected_sha256} =~ $HEX64;
    }

    _validate_content_length($opts{content_length}) if defined $opts{content_length};
    _validate_uploaded($opts{uploaded}) if defined $opts{uploaded};
    _validate_pubkey($opts{pubkey}) if defined $opts{pubkey};

    my %upload_context = (type => $type);
    $upload_context{expected_sha256} = $opts{expected_sha256} if defined $opts{expected_sha256};
    $upload_context{content_length} = $opts{content_length} if defined $opts{content_length};
    $upload_context{pubkey} = $opts{pubkey} if defined $opts{pubkey};

    my $upload = $self->storage->begin_upload(%upload_context);
    Net::Blossom::Server::Storage->assert_upload($upload);

    my $sha = Digest::SHA->new(256);
    my $size = 0;
    my $ok = eval {
        $size = $self->_copy_body_to_upload($body, $upload, $sha);
        croak "content_length mismatch"
            if defined $opts{content_length} && $size != $opts{content_length};

        my $sha256 = $sha->hexdigest;
        croak "sha256 mismatch"
            if defined $opts{expected_sha256} && $sha256 ne $opts{expected_sha256};

        my $uploaded = defined $opts{uploaded} ? $opts{uploaded} : $self->clock->();
        my %commit_metadata = (
            sha256   => $sha256,
            size     => $size,
            type     => $type,
            uploaded => $uploaded,
        );
        $commit_metadata{pubkey} = $opts{pubkey} if defined $opts{pubkey};

        my $result = _upload_result_from_commit($upload->commit(%commit_metadata));
        _validate_committed_descriptor($result->descriptor, $sha256, $size, $type);
        $result;
    };

    if (!$ok) {
        my $error = $@;
        eval { $upload->abort };
        die $error;
    }

    return $ok;
}

sub handle_upload {
    my $self = shift;
    my ($request, %opts) = @_;
    my %known = map { $_ => 1 } qw(pubkey);
    my @unknown = grep { !exists $known{$_} } keys %opts;
    croak "unknown option(s): " . join(', ', sort @unknown) if @unknown;

    croak "request must be a Net::Blossom::Server::Request"
        unless blessed($request) && $request->isa('Net::Blossom::Server::Request');
    croak "upload request method must be PUT" unless $request->method eq 'PUT';
    croak "upload request path must be /upload" unless $request->path eq '/upload';
    croak "upload request body is required" unless defined $request->body;

    my %upload_opts;
    $upload_opts{type} = $request->content_type if defined $request->content_type;
    $upload_opts{content_length} = $request->content_length if defined $request->content_length;
    $upload_opts{pubkey} = $opts{pubkey} if defined $opts{pubkey};

    my $result = $self->receive_blob($request->body, %upload_opts);
    return Net::Blossom::Server::Response->json(
        $result->descriptor->to_hash,
        status => $result->created ? 201 : 200,
    );
}

sub handle_get_blob {
    my $self = shift;
    my ($request, %opts) = @_;
    my @unknown = keys %opts;
    croak "unknown option(s): " . join(', ', sort @unknown) if @unknown;

    croak "request must be a Net::Blossom::Server::Request"
        unless blessed($request) && $request->isa('Net::Blossom::Server::Request');
    croak "blob request method must be GET" unless $request->method eq 'GET';

    my $sha256 = _sha256_from_blob_path($request->path);
    my $descriptor = $self->storage->get_blob($sha256);
    return Net::Blossom::Server::Response->empty(404) unless defined $descriptor;

    croak "storage get_blob must return a Net::Blossom::BlobDescriptor"
        unless blessed($descriptor) && $descriptor->isa('Net::Blossom::BlobDescriptor');
    croak "storage returned descriptor sha256 mismatch" unless $descriptor->sha256 eq $sha256;

    return Net::Blossom::Server::Response->json($descriptor->to_hash, status => 200);
}

sub handle_request {
    my $self = shift;
    my ($request, %opts) = @_;
    my %known = map { $_ => 1 } qw(pubkey);
    my @unknown = grep { !exists $known{$_} } keys %opts;
    croak "unknown option(s): " . join(', ', sort @unknown) if @unknown;

    croak "request must be a Net::Blossom::Server::Request"
        unless blessed($request) && $request->isa('Net::Blossom::Server::Request');

    if ($request->path eq '/upload') {
        return Net::Blossom::Server::Response->empty(405, headers => { Allow => 'PUT' })
            unless $request->method eq 'PUT';
        return $self->handle_upload($request, %opts);
    }

    if ($request->path =~ m{\A/[0-9a-f]{64}\z}) {
        return Net::Blossom::Server::Response->empty(405, headers => { Allow => 'GET' })
            unless $request->method eq 'GET';
        return $self->handle_get_blob($request);
    }

    return Net::Blossom::Server::Response->empty(404);
}

sub _sha256_from_blob_path {
    my ($path) = @_;
    my ($sha256) = defined $path ? ($path =~ m{\A/([^/]+)\z}) : ();
    croak "blob request path must be /<sha256>"
        unless defined $sha256 && length($sha256) == 64;
    croak "sha256 must be 64-char lowercase hex" unless $sha256 =~ $HEX64;
    return $sha256;
}

sub _copy_body_to_upload {
    my ($self, $body, $upload, $sha) = @_;
    my $size = 0;

    if (!ref($body)) {
        _write_upload_chunk($upload, $sha, $body);
        return length $body;
    }

    if ($body->can('read')) {
        while (1) {
            my $chunk = '';
            my $read = $body->read($chunk, $self->chunk_size);
            croak "body stream read failed" unless defined $read;
            last if $read == 0;
            _write_upload_chunk($upload, $sha, $chunk);
            $size += length $chunk;
        }
        return $size;
    }

    while (defined(my $chunk = $body->getline)) {
        _write_upload_chunk($upload, $sha, $chunk);
        $size += length $chunk;
    }
    return $size;
}

sub _write_upload_chunk {
    my ($upload, $sha, $chunk) = @_;
    croak "body chunks must be scalars" if ref($chunk);
    $sha->add($chunk);
    my $written = $upload->write($chunk);
    croak "storage write failed" unless defined $written;
}

sub _upload_result_from_commit {
    my ($committed) = @_;

    return $committed
        if blessed($committed) && $committed->isa('Net::Blossom::Server::UploadResult');

    if (ref($committed) eq 'HASH' && exists $committed->{descriptor}) {
        my $descriptor = $committed->{descriptor};
        $descriptor = Net::Blossom::BlobDescriptor->from_hash($descriptor)
            if ref($descriptor) eq 'HASH';
        return Net::Blossom::Server::UploadResult->new(
            descriptor => $descriptor,
            created    => $committed->{created},
        );
    }

    my $descriptor;
    $descriptor = $committed
        if blessed($committed) && $committed->isa('Net::Blossom::BlobDescriptor');
    $descriptor = Net::Blossom::BlobDescriptor->from_hash($committed)
        if ref($committed) eq 'HASH';
    return Net::Blossom::Server::UploadResult->new(
        descriptor => $descriptor,
        created    => 1,
    ) if defined $descriptor;

    croak "storage commit must return an upload result or blob descriptor";
}

sub _validate_committed_descriptor {
    my ($descriptor, $sha256, $size, $type) = @_;
    croak "storage returned descriptor sha256 mismatch" unless $descriptor->sha256 eq $sha256;
    croak "storage returned descriptor size mismatch" unless $descriptor->size == $size;
    croak "storage returned descriptor type mismatch" unless $descriptor->type eq $type;
}

sub _validate_body {
    my ($body) = @_;
    return unless ref($body);
    return if blessed($body) && ($body->can('read') || $body->can('getline'));
    croak "body must be a scalar or stream object";
}

sub _validate_content_length {
    my ($content_length) = @_;
    croak "content_length must be a scalar" if ref($content_length);
    croak "content_length must be a non-negative integer"
        unless $content_length =~ /\A\d+\z/;
}

sub _validate_uploaded {
    my ($uploaded) = @_;
    croak "uploaded must be a scalar" if ref($uploaded);
    croak "uploaded must be a non-negative integer"
        unless $uploaded =~ /\A\d+\z/;
}

sub _validate_pubkey {
    my ($pubkey) = @_;
    croak "pubkey must be a scalar" if ref($pubkey);
    croak "pubkey must be 64-char lowercase hex" unless $pubkey =~ $HEX64;
}

1;

=pod

=head1 NAME

Net::Blossom::Server - Server-side support for the Blossom protocol

=head1 SYNOPSIS

    use Net::Blossom::Server;

    my $server = Net::Blossom::Server->new(
        storage => $storage,
    );

=head1 DESCRIPTION

C<Net::Blossom::Server> is the framework-neutral server core for the Blossom
protocol. Gateway adapters such as PSGI or PAGI should translate native requests
into C<Net::Blossom::Server::Request> objects and translate
C<Net::Blossom::Server::Response> objects back to their gateway format.

Server support lives in a separate CPAN distribution so client users do not need
server, storage, daemon, or web framework dependencies.

=head1 CONSTRUCTOR

=head2 new

    my $server = Net::Blossom::Server->new(%args);

Required arguments:

=over 4

=item * C<storage>

Storage object that satisfies L<Net::Blossom::Server::Storage>.

=back

Optional arguments:

=over 4

=item * C<chunk_size>

Positive integer read size used when copying stream bodies. Defaults to C<65536>.

=item * C<clock>

Code reference returning the upload timestamp. Defaults to C<time>.

=back

Unknown arguments or invalid values croak.

=head1 ACCESSORS

=head2 storage

Returns the configured storage object.

=head2 chunk_size

Returns the stream copy chunk size.

=head2 clock

Returns the clock code reference.

=head1 METHODS

=head2 receive_blob

    my $result = $server->receive_blob($body, %opts);

Copies a scalar or stream body into storage while computing SHA-256 in the server
core. Returns a C<Net::Blossom::Server::UploadResult>.

Options:

=over 4

=item * C<type>

Blob media type. Defaults to C<application/octet-stream>.

=item * C<expected_sha256>

Optional lowercase 64-character SHA-256 hash. When present, the computed hash
must match before the upload is committed.

=item * C<content_length>

Optional expected body size. When present, the copied byte count must match
before the upload is committed.

=item * C<uploaded>

Optional upload timestamp. Defaults to C<< $server->clock->() >>.

=item * C<pubkey>

Optional uploader public key as lowercase 64-character hex. Gateway adapters
will normally derive this from BUD-11 authorization.

=back

The storage upload is aborted if hashing, length validation, SHA-256 validation,
or storage writing fails.

Storage commit results that are raw C<Net::Blossom::BlobDescriptor> objects or
descriptor hash references are accepted as newly created uploads for compatibility
with early storage implementations. New storage implementations should return a
C<Net::Blossom::Server::UploadResult> or a hash reference with C<descriptor> and
C<created>.

=head2 handle_upload

    my $response = $server->handle_upload($request, %opts);

Handles a normalized C<PUT /upload> request and returns a
C<Net::Blossom::Server::Response>. The request must be a
C<Net::Blossom::Server::Request> with a defined body.

The method passes the request body, content type, content length, and optional
C<pubkey> into C<receive_blob>. The response body is the blob descriptor encoded
as JSON. The response status is C<201> when the blob was newly stored and C<200>
when it already existed.

Options:

=over 4

=item * C<pubkey>

Optional already-verified uploader public key as lowercase 64-character hex.
Authorization verification is deliberately outside this method.

=back

=head2 handle_get_blob

    my $response = $server->handle_get_blob($request);

Handles a normalized C<GET /E<lt>sha256E<gt>> request and returns a
C<Net::Blossom::Server::Response>. The request path must contain one lowercase
64-character SHA-256 hash segment.

The method calls C<< $server->storage->get_blob($sha256) >>. It returns C<404>
when storage returns C<undef>. Otherwise, storage must return a
C<Net::Blossom::BlobDescriptor> whose C<sha256> matches the request path, and
the response body is that descriptor encoded as JSON with status C<200>.

=head2 handle_request

    my $response = $server->handle_request($request, %opts);

Dispatches a normalized C<Net::Blossom::Server::Request> and returns a
C<Net::Blossom::Server::Response>. This is the framework-neutral routing entry
point for future gateway adapters.

Currently implemented routes:

=over 4

=item * C<PUT /upload>

Delegates to C<handle_upload>.

=item * C<GET /E<lt>sha256E<gt>>

Delegates to C<handle_get_blob>.

=back

Unknown paths return C<404>. Known paths with unsupported methods return C<405>.

Options:

=over 4

=item * C<pubkey>

Optional already-verified uploader public key. Passed through to C<handle_upload>
for upload requests.

=back

=head1 STATUS

The server core is under active development. Additional endpoint handlers and
gateway adapters are not implemented yet.

=cut
