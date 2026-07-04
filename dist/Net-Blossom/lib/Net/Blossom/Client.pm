package Net::Blossom::Client;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();
use Net::Blossom::BlobDescriptor;
use Net::Blossom::Error;
use Net::Blossom::PaymentRequired;
use Net::Blossom::Response;
use Net::Blossom::ServerList;

use Carp qw(croak);
use Class::Tiny qw(server ua auth);
use Digest::SHA qw(sha256_hex);
use HTTP::Tiny;
use JSON ();
use MIME::Base64 qw(decode_base64);
use Net::Nostr::Zap qw(bolt11_amount);
use Scalar::Util qw(blessed);

my $HEX64 = qr/\A[0-9a-f]{64}\z/;
my $HEX128 = qr/\A[0-9a-f]{128}\z/;
my $JSON = JSON->new->utf8;
my $CANONICAL_JSON = JSON->new->utf8->canonical;
my %RESERVED_PAYMENT_METHOD = map { $_ => 1 } qw(reason sha-256 content-type content-length);
my $BECH32_CHARS = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
my %BECH32_VALUE = map { substr($BECH32_CHARS, $_, 1) => $_ } 0 .. length($BECH32_CHARS) - 1;
my @BECH32_GENERATOR = (0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3);

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
        payment => $opts{payment},
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
        payment => $opts{payment},
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
        payment => $opts{payment},
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
        payment => $opts{payment},
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
        payment => $opts{payment},
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
        payment => $opts{payment},
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
    my ($url, %opts) = @_;
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
        payment => $opts{payment},
        ok      => { 200 => 1, 201 => 1 },
    );

    return Net::Blossom::BlobDescriptor->from_hash(_decode_json_hash($response->content));
}

sub report_blob {
    my $self = shift;
    my ($event, %opts) = @_;
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
        payment => $opts{payment},
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
        payment => $opts{payment},
        ok     => { 200 => 1 },
    );

    my $data = _decode_json($response->content);
    croak "list response must be a JSON array" unless ref($data) eq 'ARRAY';
    return [map { Net::Blossom::BlobDescriptor->from_hash($_) } @$data];
}

sub delete_blob {
    my $self = shift;
    my ($sha256, %opts) = @_;
    _validate_sha256($sha256);

    return $self->_request(
        method => 'DELETE',
        path   => "/$sha256",
        action => 'delete',
        sha256 => $sha256,
        payment => $opts{payment},
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

    if (defined $args{payment}) {
        croak "payment proof headers are not allowed on HEAD requests"
            if $method eq 'HEAD';
        my %payment_headers = _payment_headers($args{payment});
        @headers{keys %payment_headers} = values %payment_headers;
    }

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

    if ($response->status == 402) {
        die Net::Blossom::PaymentRequired->new(
            method             => $method,
            url                => $url,
            status             => $response->status,
            reason             => $response->reason,
            x_reason           => $response->header('x-reason'),
            headers            => $response->headers,
            body               => $response->content,
            payment_challenges => _payment_challenges($response->headers),
        );
    }

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
    my %context = (
        method => $args{method},
        url    => $args{url},
        action => $args{action},
        sha256 => $args{sha256},
    );

    return $self->auth->(%context) if ref($self->auth) eq 'CODE';

    return $self->auth->authorization_header(%context)
        if blessed($self->auth) && $self->auth->can('authorization_header');

    croak "auth must be a string, code reference, or object with authorization_header";
}

sub _server_values {
    my ($servers) = @_;
    croak "servers are required" unless defined $servers;

    return @{$servers->servers}
        if ref($servers) && eval { $servers->isa('Net::Blossom::ServerList') };

    croak "servers must be a Net::Blossom::ServerList or array reference"
        unless ref($servers) eq 'ARRAY';

    return @{Net::Blossom::ServerList->new(servers => $servers)->servers};
}

sub _payment_headers {
    my ($payment) = @_;
    croak "payment must be a hash reference" unless ref($payment) eq 'HASH';

    my %headers;
    for my $method (sort keys %$payment) {
        my $normalized = _normalize_payment_method($method);
        my $proof = $payment->{$method};
        croak "payment proof for $normalized is required"
            unless defined $proof && length $proof;
        croak "payment proof for $normalized must be a scalar" if ref($proof);
        $headers{_payment_header_name($normalized)} = $proof;
    }

    croak "payment requires at least one proof" unless %headers;
    return %headers;
}

sub _payment_challenges {
    my ($headers) = @_;
    my %challenges;

    for my $header (sort keys %{$headers || {}}) {
        next unless $header =~ /\AX-/i;
        my $method = _payment_challenge_method($header);
        next unless defined $method;
        my $payload = $headers->{$header};
        next if ref($payload);
        next unless defined $payload && length $payload;
        next unless _valid_payment_challenge($method, $payload);
        $challenges{$method} = $payload;
    }

    return \%challenges;
}

sub _valid_payment_challenge {
    my ($method, $payload) = @_;
    return _valid_cashu_challenge($payload) if $method eq 'cashu';
    return _valid_lightning_challenge($payload) if $method eq 'lightning';
    return 1;
}

sub _valid_cashu_challenge {
    my ($payload) = @_;
    return 0 unless defined $payload && !ref($payload) && $payload =~ /\AcreqA([A-Za-z0-9_-]+={0,2})\z/;

    my $bytes = _decode_base64url($1);
    return 0 unless defined $bytes && length $bytes;

    my ($request, $pos) = _cbor_decode($bytes, 0, 0);
    return 0 unless defined $pos && $pos == length($bytes) && ref($request) eq 'HASH';
    return _valid_cashu_request($request);
}

sub _valid_cashu_request {
    my ($request) = @_;
    return 0 unless exists $request->{a} && defined $request->{a} && !ref($request->{a});
    return 0 unless "$request->{a}" =~ /\A\d+\z/ && $request->{a} > 0;
    return 0 unless exists $request->{u} && defined $request->{u} && !ref($request->{u}) && length $request->{u};
    return 0 unless exists $request->{m} && ref($request->{m}) eq 'ARRAY' && @{$request->{m}};

    for my $mint (@{$request->{m}}) {
        return 0 unless defined $mint && !ref($mint) && length $mint;
    }

    return 1;
}

sub _decode_base64url {
    my ($encoded) = @_;
    return unless defined $encoded && !ref($encoded) && $encoded =~ /\A[A-Za-z0-9_-]+={0,2}\z/;

    $encoded =~ s/=+\z//;
    return if length($encoded) % 4 == 1;
    $encoded =~ tr{-_}{+/};
    $encoded .= '=' while length($encoded) % 4;
    return decode_base64($encoded);
}

sub _cbor_decode {
    my ($bytes, $pos, $depth) = @_;
    return if $depth > 32 || $pos >= length($bytes);

    my $initial = ord substr($bytes, $pos, 1);
    my $major = $initial >> 5;
    my $additional = $initial & 0x1f;
    my ($arg, $next) = _cbor_argument($bytes, $pos + 1, $additional);
    return unless defined $next;
    $pos = $next;

    return ($arg, $pos) if $major == 0;
    return (-1 - $arg, $pos) if $major == 1;

    if ($major == 2 || $major == 3) {
        return if $pos + $arg > length($bytes);
        return (substr($bytes, $pos, $arg), $pos + $arg);
    }

    if ($major == 4) {
        my @values;
        for (1 .. $arg) {
            my ($value, $value_pos) = _cbor_decode($bytes, $pos, $depth + 1);
            return unless defined $value_pos;
            push @values, $value;
            $pos = $value_pos;
        }
        return (\@values, $pos);
    }

    if ($major == 5) {
        my %map;
        for (1 .. $arg) {
            my ($key, $key_pos) = _cbor_decode($bytes, $pos, $depth + 1);
            return unless defined $key_pos && defined $key && !ref($key);
            my ($value, $value_pos) = _cbor_decode($bytes, $key_pos, $depth + 1);
            return unless defined $value_pos;
            $map{$key} = $value;
            $pos = $value_pos;
        }
        return (\%map, $pos);
    }

    return _cbor_decode($bytes, $pos, $depth + 1) if $major == 6;

    if ($major == 7) {
        return (0, $pos) if $additional == 20;
        return (1, $pos) if $additional == 21;
        return (undef, $pos) if $additional == 22 || $additional == 23;
        return ($arg, $pos);
    }

    return;
}

sub _cbor_argument {
    my ($bytes, $pos, $additional) = @_;
    return ($additional, $pos) if $additional < 24;

    my $size = $additional == 24 ? 1
        : $additional == 25 ? 2
        : $additional == 26 ? 4
        : $additional == 27 ? 8
        : undef;
    return unless defined $size && $pos + $size <= length($bytes);

    my $value = 0;
    for my $offset (0 .. $size - 1) {
        $value = ($value << 8) + ord substr($bytes, $pos + $offset, 1);
    }

    return ($value, $pos + $size);
}

sub _valid_lightning_challenge {
    my ($payload) = @_;
    my ($hrp) = _bech32_parts($payload);
    return 0 unless defined $hrp && $hrp =~ /\Aln(?:bc|tb|bcrt|sb)(?:\d+[munp]?)?\z/;
    return 0 unless _valid_bech32($payload);
    return eval { bolt11_amount(lc $payload); 1 } ? 1 : 0;
}

sub _valid_bech32 {
    my ($value) = @_;
    my ($hrp, $data) = _bech32_parts($value);
    return 0 unless defined $hrp;

    my @values = (_bech32_hrp_expand($hrp), map { $BECH32_VALUE{$_} } split //, $data);
    return _bech32_polymod(\@values) == 1;
}

sub _bech32_parts {
    my ($value) = @_;
    return unless defined $value && !ref($value) && length $value;
    return if $value =~ /[^\x21-\x7e]/;
    return if lc($value) ne $value && uc($value) ne $value;

    my $normalized = lc $value;
    my $separator = rindex($normalized, '1');
    return if $separator < 1;

    my $data = substr($normalized, $separator + 1);
    return if length($data) < 6;
    return unless $data =~ /\A[$BECH32_CHARS]+\z/;

    return (substr($normalized, 0, $separator), $data);
}

sub _bech32_hrp_expand {
    my ($hrp) = @_;
    my @chars = split //, $hrp;
    return ((map { ord($_) >> 5 } @chars), 0, (map { ord($_) & 31 } @chars));
}

sub _bech32_polymod {
    my ($values) = @_;
    my $chk = 1;

    for my $value (@$values) {
        my $top = $chk >> 25;
        $chk = (($chk & 0x1ffffff) << 5) ^ $value;
        for my $i (0 .. 4) {
            $chk ^= $BECH32_GENERATOR[$i] if (($top >> $i) & 1);
        }
    }

    return $chk;
}

sub _payment_challenge_method {
    my ($method) = @_;
    return undef unless defined $method && length $method;
    $method =~ s/\AX-//i;
    return undef unless $method =~ /\A[A-Za-z0-9][A-Za-z0-9-]*\z/;

    my $normalized = lc $method;
    return undef if $RESERVED_PAYMENT_METHOD{$normalized};
    return $normalized;
}

sub _normalize_payment_method {
    my ($method) = @_;
    croak "payment method is required" unless defined $method && length $method;
    $method =~ s/\AX-//i;
    croak "payment method must be an X- header token"
        unless $method =~ /\A[A-Za-z0-9][A-Za-z0-9-]*\z/;

    my $normalized = lc $method;
    croak "payment method $normalized is reserved"
        if $RESERVED_PAYMENT_METHOD{$normalized};
    return $normalized;
}

sub _payment_header_name {
    my ($method) = @_;
    return 'X-' . join '-', map { ucfirst lc $_ } split /-/, $method;
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
