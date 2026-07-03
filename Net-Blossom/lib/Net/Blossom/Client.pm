package Net::Blossom::Client;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();
use Net::Blossom::BlobDescriptor;
use Net::Blossom::Error;
use Net::Blossom::Response;

use Carp qw(croak);
use Class::Tiny qw(server ua auth);
use Digest::SHA qw(sha256_hex);
use HTTP::Tiny;
use JSON::PP ();

my $HEX64 = qr/\A[0-9a-f]{64}\z/;
my $JSON = JSON::PP->new->utf8;

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(server ua auth);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;
    croak "server is required" unless defined $args{server} && length $args{server};

    $args{server} =~ s{/+\z}{};
    $args{ua} = HTTP::Tiny->new unless defined $args{ua};

    return bless \%args, $class;
}

sub get_blob {
    my $self = shift;
    my ($sha256, %opts) = @_;
    _validate_sha256($sha256);

    my %headers;
    $headers{Range} = $opts{range} if defined $opts{range};

    return $self->_request(
        method  => 'GET',
        path    => $self->_blob_path($sha256, $opts{extension}),
        headers => \%headers,
        action  => 'get',
        sha256  => $sha256,
        ok      => { map { $_ => 1 } qw(200 206 307 308) },
    );
}

sub head_blob {
    my $self = shift;
    my ($sha256, %opts) = @_;
    _validate_sha256($sha256);

    return $self->_request(
        method => 'HEAD',
        path   => $self->_blob_path($sha256, $opts{extension}),
        action => 'get',
        sha256 => $sha256,
        ok     => { map { $_ => 1 } qw(200 307 308) },
    );
}

sub upload_blob {
    my $self = shift;
    my ($content, %opts) = @_;
    croak "content is required" unless defined $content;

    my $sha256 = sha256_hex($content);
    my %headers = (
        'Content-Type'   => $opts{type} || 'application/octet-stream',
        'Content-Length' => length($content),
        'X-SHA-256'      => $sha256,
    );

    my $response = $self->_request(
        method  => 'PUT',
        path    => '/upload',
        headers => \%headers,
        content => $content,
        action  => 'upload',
        sha256  => $sha256,
        ok      => { 200 => 1, 201 => 1 },
    );

    return Net::Blossom::BlobDescriptor->from_hash(_decode_json_hash($response->content));
}

sub list_blobs {
    my $self = shift;
    my ($pubkey, %opts) = @_;
    croak "pubkey must be 64-char lowercase hex" unless defined $pubkey && $pubkey =~ $HEX64;

    my @query;
    for my $field (qw(cursor limit since until)) {
        next unless defined $opts{$field};
        push @query, _uri_escape($field) . '=' . _uri_escape($opts{$field});
    }

    my $path = "/list/$pubkey";
    $path .= '?' . join('&', @query) if @query;

    my $response = $self->_request(
        method => 'GET',
        path   => $path,
        action => 'list',
        ok     => { 200 => 1 },
    );

    my $data = _decode_json($response->content);
    croak "list response must be a JSON array" unless ref($data) eq 'ARRAY';
    return map { Net::Blossom::BlobDescriptor->from_hash($_) } @$data;
}

sub delete_blob {
    my $self = shift;
    my ($sha256) = @_;
    _validate_sha256($sha256);

    return $self->_request(
        method => 'DELETE',
        path   => "/$sha256",
        action => 'delete',
        sha256 => $sha256,
        ok     => { 200 => 1, 204 => 1 },
    );
}

sub _request {
    my $self = shift;
    my %args = @_;
    my $method = $args{method};
    my $url = $self->server . $args{path};
    my %headers = %{ $args{headers} || {} };

    if (my $authorization = $self->_authorization_header(%args, url => $url)) {
        $headers{Authorization} = $authorization;
    }

    my %request = (headers => \%headers);
    $request{content} = $args{content} if exists $args{content};

    my $raw = $self->ua->request($method, $url, \%request);
    my $response = Net::Blossom::Response->new(
        method  => $method,
        url     => $url,
        status  => $raw->{status},
        reason  => $raw->{reason},
        headers => $raw->{headers} || {},
        content => $raw->{content},
    );

    my $ok = $args{ok} || {};
    return $response if $ok->{$response->status};

    die Net::Blossom::Error->new(
        method   => $method,
        url      => $url,
        status   => $response->status,
        reason   => $response->reason,
        x_reason => $response->header('x-reason'),
        headers  => $response->headers,
        body     => $response->content,
    );
}

sub _authorization_header {
    my $self = shift;
    my %args = @_;
    return undef unless defined $self->auth;
    return $self->auth unless ref $self->auth;
    croak "auth must be a string or code reference" unless ref($self->auth) eq 'CODE';
    return $self->auth->(
        method => $args{method},
        url    => $args{url},
        action => $args{action},
        sha256 => $args{sha256},
    );
}

sub _blob_path {
    my ($self, $sha256, $extension) = @_;
    return "/$sha256" unless defined $extension && length $extension;
    croak "extension must contain only letters and digits"
        unless $extension =~ /\A[A-Za-z0-9]+\z/;
    return "/$sha256.$extension";
}

sub _validate_sha256 {
    my ($sha256) = @_;
    croak "sha256 must be 64-char lowercase hex"
        unless defined $sha256 && $sha256 =~ $HEX64;
}

sub _decode_json_hash {
    my ($content) = @_;
    my $data = _decode_json($content);
    croak "response body must be a JSON object" unless ref($data) eq 'HASH';
    return $data;
}

sub _decode_json {
    my ($content) = @_;
    my $data = eval { $JSON->decode($content) };
    croak "invalid JSON response: $@" if $@;
    return $data;
}

sub _uri_escape {
    my ($value) = @_;
    $value = "$value";
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge;
    return $value;
}

1;
