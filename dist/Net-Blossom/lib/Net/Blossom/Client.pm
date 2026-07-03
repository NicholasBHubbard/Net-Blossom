package Net::Blossom::Client;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();
use Net::Blossom::BlobDescriptor;
use Net::Blossom::Error;
use Net::Blossom::Response;
use Net::Blossom::ServerList;

use Carp qw(croak);
use Class::Tiny qw(server ua auth);
use Digest::SHA qw(sha256_hex);
use HTTP::Tiny;
use JSON::PP ();

my $HEX64 = qr/\A[0-9a-f]{64}\z/;
my $HEX128 = qr/\A[0-9a-f]{128}\z/;
my $JSON = JSON::PP->new->utf8;
my $CANONICAL_JSON = JSON::PP->new->utf8->canonical;

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

sub head_upload {
    my $self = shift;
    my ($content, %opts) = @_;
    croak "content is required" unless defined $content;

    my $sha256 = sha256_hex($content);
    my %headers = (
        'X-SHA-256'        => $sha256,
        'X-Content-Type'   => $opts{type} || 'application/octet-stream',
        'X-Content-Length' => length($content),
    );

    return $self->_request(
        method  => 'HEAD',
        path    => '/upload',
        headers => \%headers,
        action  => 'upload',
        sha256  => $sha256,
        ok      => { 200 => 1 },
    );
}

sub process_media {
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
        path    => '/media',
        headers => \%headers,
        content => $content,
        action  => 'media',
        sha256  => $sha256,
        ok      => { 200 => 1, 201 => 1 },
    );

    return Net::Blossom::BlobDescriptor->from_hash(_decode_json_hash($response->content));
}

sub head_media {
    my $self = shift;
    my ($content, %opts) = @_;
    croak "content is required" unless defined $content;

    my $sha256 = sha256_hex($content);
    my %headers = (
        'X-SHA-256'        => $sha256,
        'X-Content-Type'   => $opts{type} || 'application/octet-stream',
        'X-Content-Length' => length($content),
    );

    return $self->_request(
        method  => 'HEAD',
        path    => '/media',
        headers => \%headers,
        action  => 'media',
        sha256  => $sha256,
        ok      => { 200 => 1 },
    );
}

sub upload_blob_to_servers {
    my $self = shift;
    my ($content, $servers, %opts) = @_;
    my @servers = _server_values($servers);

    return $self->_client_for_server($servers[0])->upload_blob($content, %opts);
}

sub mirror_blob {
    my $self = shift;
    my ($url) = @_;
    croak "url is required" unless defined $url && length $url;
    croak "url must be a string" if ref($url);

    my $content = $CANONICAL_JSON->encode({ url => $url });
    my %headers = (
        'Content-Type'   => 'application/json',
        'Content-Length' => length($content),
    );
    my ($sha256) = Net::Blossom::ServerList->extract_blob_reference($url);

    my $response = $self->_request(
        method  => 'PUT',
        path    => '/mirror',
        headers => \%headers,
        content => $content,
        action  => 'upload',
        sha256  => $sha256,
        ok      => { 200 => 1, 201 => 1 },
    );

    return Net::Blossom::BlobDescriptor->from_hash(_decode_json_hash($response->content));
}

sub report_blob {
    my $self = shift;
    my ($event) = @_;
    _validate_report_event($event);

    my $content = $CANONICAL_JSON->encode($event);
    my %headers = (
        'Content-Type'   => 'application/json',
        'Content-Length' => length($content),
    );

    return $self->_request(
        method  => 'PUT',
        path    => '/report',
        headers => \%headers,
        content => $content,
        action  => 'report',
        ok      => { map { $_ => 1 } 200 .. 299 },
    );
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

sub get_blob_from_servers {
    my $self = shift;
    my ($url, $servers, %opts) = @_;
    my ($sha256, $extension) = Net::Blossom::ServerList->extract_blob_reference($url);
    croak "URL does not contain a sha256 hash" unless defined $sha256;

    my @servers = _server_values($servers);
    my $last_error;

    for my $server (@servers) {
        my %get_opts = %opts;
        $get_opts{extension} = $extension
            if defined $extension && !defined $get_opts{extension};

        my $response = eval {
            $self->_client_for_server($server)->get_blob($sha256, %get_opts);
        };
        return $response unless $@;

        my $error = $@;
        die $error unless ref($error) && eval { $error->isa('Net::Blossom::Error') };
        $last_error = $error;
    }

    die $last_error if defined $last_error;
    croak "server list must contain at least one server";
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

sub _client_for_server {
    my ($self, $server) = @_;
    return ref($self)->new(
        server => $server,
        ua     => $self->ua,
        auth   => $self->auth,
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

sub _server_values {
    my ($servers) = @_;
    croak "servers are required" unless defined $servers;

    return $servers->servers
        if ref($servers) && eval { $servers->isa('Net::Blossom::ServerList') };

    croak "servers must be a Net::Blossom::ServerList or array reference"
        unless ref($servers) eq 'ARRAY';

    return Net::Blossom::ServerList->new(servers => $servers)->servers;
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

sub _validate_report_event {
    my ($event) = @_;
    croak "report event must be a hash reference" unless ref($event) eq 'HASH';

    _validate_report_hex_field($event, 'id', $HEX64, '64-char lowercase hex');
    _validate_report_hex_field($event, 'pubkey', $HEX64, '64-char lowercase hex');
    _validate_report_hex_field($event, 'sig', $HEX128, '128-char lowercase hex');

    croak "report event created_at must be a non-negative integer"
        unless defined $event->{created_at} && !ref($event->{created_at})
            && $event->{created_at} =~ /\A\d+\z/;
    croak "report event kind must be 1984"
        unless defined $event->{kind} && !ref($event->{kind})
            && $event->{kind} =~ /\A1984\z/;
    croak "report event content must be a scalar"
        unless defined $event->{content} && !ref($event->{content});
    croak "report event tags must be an array reference"
        unless ref($event->{tags}) eq 'ARRAY';

    my $has_x;
    for my $tag (@{$event->{tags}}) {
        croak "report event tags must be array references" unless ref($tag) eq 'ARRAY';
        croak "report event tag values must be defined" if grep { !defined $_ } @$tag;
        croak "report event tag values must be scalars" if grep { ref($_) } @$tag;

        next unless @$tag && $tag->[0] eq 'x';
        croak "report x tags must contain a sha256 hash" unless @$tag >= 2;
        croak "report x tag hash must be 64-char lowercase hex"
            unless $tag->[1] =~ $HEX64;
        $has_x = 1;
    }

    croak "report event must contain at least one x tag" unless $has_x;
}

sub _validate_report_hex_field {
    my ($event, $field, $regex, $description) = @_;
    croak "report event $field must be $description"
        unless defined $event->{$field} && !ref($event->{$field})
            && $event->{$field} =~ $regex;
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
