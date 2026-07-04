use strictures 2;

use Test::More;
use Digest::SHA qw(sha256_hex);
use JSON ();

use Net::Blossom::AuthToken;
use Net::Blossom::BlobDescriptor;
use Net::Blossom::Server;
use Net::Blossom::Server::Authorization;
use Net::Blossom::Server::BlobResult;
use Net::Blossom::Server::Error;
use Net::Blossom::Server::PSGI;
use Net::Nostr::Key;

my $PUBKEY = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
my $SHA256 = '0f343b0931126a20f133d67c2b018a3b5ceca63dd3585a76cb1f3289a274707f';
my $NOW = time;
my $JSON = JSON->new->utf8->canonical;

sub dies(&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

{
    package Local::Input;
    use strictures 2;

    sub new {
        my ($class, $data) = @_;
        return bless { data => $data, offset => 0 }, $class;
    }

    sub read {
        my ($self, undef, $length) = @_;
        return 0 if $self->{offset} >= length $self->{data};
        $_[1] = substr($self->{data}, $self->{offset}, $length);
        $self->{offset} += length $_[1];
        return length $_[1];
    }
}

{
    package Local::Storage;
    use strictures 2;

    sub new {
        my ($class, %args) = @_;
        return bless {
            uploads    => [],
            blobs      => $args{blobs} || {},
            list_blobs => $args{list_blobs} || [],
        }, $class;
    }

    sub begin_upload {
        my ($self, %context) = @_;
        my $upload = Local::Upload->new($self, \%context);
        push @{$self->{uploads}}, $upload;
        return $upload;
    }

    sub get_blob {
        my ($self, $sha256) = @_;
        $self->{last_get_blob} = $sha256;
        return $self->{blobs}{$sha256};
    }

    sub delete_blob {
        my ($self, $sha256, %opts) = @_;
        $self->{last_delete_blob} = [$sha256, \%opts];
        return 1;
    }

    sub list_blobs {
        my ($self, $pubkey, %opts) = @_;
        $self->{last_list_blobs} = [$pubkey, \%opts];
        return $self->{list_blobs};
    }

    sub uploads {
        my ($self) = @_;
        return @{$self->{uploads}};
    }
}

{
    package Local::Upload;
    use strictures 2;

    sub new {
        my ($class, $storage, $context) = @_;
        return bless {
            storage => $storage,
            context => $context,
            chunks  => [],
        }, $class;
    }

    sub write {
        my ($self, $chunk) = @_;
        push @{$self->{chunks}}, $chunk;
        return length $chunk;
    }

    sub commit {
        my ($self, %metadata) = @_;
        $self->{commit} = \%metadata;
        return {
            descriptor => {
                url      => "https://cdn.example.com/$metadata{sha256}.bin",
                sha256   => $metadata{sha256},
                size     => $metadata{size},
                type     => $metadata{type},
                uploaded => $metadata{uploaded},
            },
            created => 1,
        };
    }

    sub abort {
        return 1;
    }
}

sub env {
    my (%args) = @_;
    return {
        REQUEST_METHOD => $args{method},
        PATH_INFO      => $args{path},
        QUERY_STRING   => defined $args{query} ? $args{query} : '',
        REMOTE_ADDR    => '203.0.113.7',
        'psgi.input'   => Local::Input->new(defined $args{body} ? $args{body} : ''),
        %{ $args{env} || {} },
    };
}

sub headers_hash {
    my ($pairs) = @_;
    my %headers;
    while (@$pairs) {
        my $name = shift @$pairs;
        my $value = shift @$pairs;
        $headers{lc $name} = $value;
    }
    return \%headers;
}

sub auth_header {
    my ($key, %args) = @_;
    return Net::Blossom::AuthToken->new(
        key        => $key,
        action     => $args{action},
        content    => $args{content} || 'Authorize Blossom request',
        expiration => $args{expiration} || $NOW + 3600,
        hashes     => $args{hashes} || [],
        servers    => $args{servers} || [],
        created_at => exists $args{created_at} ? $args{created_at} : $NOW - 1,
    )->authorization_header;
}

subtest 'constructs PSGI adapter and app coderef' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);
    my $adapter = Net::Blossom::Server::PSGI->new(server => $server);

    isa_ok($adapter, 'Net::Blossom::Server::PSGI');
    is($adapter->server, $server, 'server accessor');
    is(ref($adapter->to_app), 'CODE', 'to_app returns PSGI coderef');
};

subtest 'PSGI app translates PUT upload requests' => sub {
    my $storage = Local::Storage->new;
    my $server = Net::Blossom::Server->new(storage => $storage, clock => sub { 1725105921 });
    my @auth_seen;
    my $app = Net::Blossom::Server::PSGI->new(
        server    => $server,
        authorize => sub {
            my %ctx = @_;
            push @auth_seen, \%ctx;
            return $PUBKEY;
        },
    )->to_app;
    my $body = "psgi upload\n";

    my $response = $app->(env(
        method => 'PUT',
        path   => '/upload',
        body   => $body,
        env    => {
            CONTENT_TYPE       => 'text/plain',
            CONTENT_LENGTH     => length($body),
            HTTP_AUTHORIZATION => 'Nostr token',
        },
    ));

    is($response->[0], 201, 'upload status');
    my $headers = headers_hash([@{$response->[1]}]);
    is($headers->{'content-type'}, 'application/json', 'json content type');
    is($JSON->decode(join '', @{$response->[2]})->{sha256}, sha256_hex($body), 'descriptor response body');

    is(scalar @auth_seen, 1, 'authorize callback called once');
    isa_ok($auth_seen[0]{request}, 'Net::Blossom::Server::Request');
    is($auth_seen[0]{request}->header('authorization'), 'Nostr token', 'authorization header translated');
    is($auth_seen[0]{request}->remote_addr, '203.0.113.7', 'remote address translated');

    my ($upload) = $storage->uploads;
    is($upload->{context}{type}, 'text/plain', 'content type passed to storage');
    is($upload->{context}{content_length}, length($body), 'content length passed to storage');
    is($upload->{context}{pubkey}, $PUBKEY, 'pubkey from authorize passed to storage');
    is_deeply($upload->{chunks}, [$body], 'psgi.input body reached storage');
};

subtest 'PSGI app translates GET blob responses' => sub {
    my $body = 'hello blob';
    my $descriptor = Net::Blossom::BlobDescriptor->new(
        url      => "https://cdn.example.com/$SHA256",
        sha256   => $SHA256,
        size     => length($body),
        type     => 'text/plain',
        uploaded => 1725105921,
    );
    my $storage = Local::Storage->new(blobs => {
        $SHA256 => Net::Blossom::Server::BlobResult->new(
            descriptor => $descriptor,
            body       => $body,
        ),
    });
    my $app = Net::Blossom::Server::PSGI->new(
        server => Net::Blossom::Server->new(storage => $storage),
    )->to_app;

    my $response = $app->(env(method => 'GET', path => "/$SHA256"));

    is($response->[0], 200, 'get status');
    my $headers = headers_hash([@{$response->[1]}]);
    is($headers->{'content-type'}, 'text/plain', 'content type');
    is($headers->{'content-length'}, length($body), 'content length');
    is_deeply($response->[2], [$body], 'scalar response body converted to PSGI array body');
    is($storage->{last_get_blob}, $SHA256, 'sha256 passed to storage');
};

subtest 'PSGI app parses query string for list requests' => sub {
    my $descriptor = Net::Blossom::BlobDescriptor->new(
        url      => "https://cdn.example.com/$SHA256",
        sha256   => $SHA256,
        size     => 12,
        type     => 'text/plain',
        uploaded => 1725105921,
    );
    my $storage = Local::Storage->new(list_blobs => [$descriptor]);
    my $app = Net::Blossom::Server::PSGI->new(
        server => Net::Blossom::Server->new(storage => $storage),
    )->to_app;

    my $response = $app->(env(
        method => 'GET',
        path   => "/list/$PUBKEY",
        query  => "cursor=$SHA256&limit=2",
    ));

    is($response->[0], 200, 'list status');
    is_deeply($JSON->decode(join '', @{$response->[2]}), [$descriptor->to_hash], 'list body');
    is_deeply($storage->{last_list_blobs}, [$PUBKEY, { cursor => $SHA256, limit => 2 }],
        'query parameters passed to storage');
};

subtest 'PSGI app passes authorized pubkey to delete requests' => sub {
    my $storage = Local::Storage->new;
    my $app = Net::Blossom::Server::PSGI->new(
        server    => Net::Blossom::Server->new(storage => $storage),
        authorize => sub { return $PUBKEY },
    )->to_app;

    my $response = $app->(env(method => 'DELETE', path => "/$SHA256"));

    is($response->[0], 204, 'delete status');
    is_deeply($response->[2], [''], 'empty body converted to PSGI array body');
    is_deeply($storage->{last_delete_blob}, [$SHA256, { pubkey => $PUBKEY }],
        'authorized pubkey passed to delete storage');
};

subtest 'PSGI app validates BUD-11 authorization' => sub {
    my $key = Net::Nostr::Key->new;
    my $storage = Local::Storage->new;
    my $app = Net::Blossom::Server::PSGI->new(
        server        => Net::Blossom::Server->new(storage => $storage, clock => sub { 1725105921 }),
        authorization => Net::Blossom::Server::Authorization->new(
            domains => ['cdn.example.com'],
            clock   => sub { $NOW },
        ),
    )->to_app;
    my $body = 'bud-11 psgi upload';
    my $sha256 = sha256_hex($body);

    my $response = $app->(env(
        method => 'PUT',
        path   => '/upload',
        body   => $body,
        env    => {
            CONTENT_TYPE       => 'text/plain',
            CONTENT_LENGTH     => length($body),
            HTTP_X_SHA_256     => $sha256,
            HTTP_AUTHORIZATION => auth_header(
                $key,
                action  => 'upload',
                hashes  => [$sha256],
                servers => ['cdn.example.com'],
            ),
        },
    ));

    is($response->[0], 201, 'authorized upload status');
    my ($upload) = $storage->uploads;
    is($upload->{context}{pubkey}, $key->pubkey_hex, 'BUD-11 pubkey passed to storage');
};

subtest 'PSGI app maps BUD-11 authorization failures to 401 responses' => sub {
    my $storage = Local::Storage->new;
    my $app = Net::Blossom::Server::PSGI->new(
        server        => Net::Blossom::Server->new(storage => $storage),
        authorization => Net::Blossom::Server::Authorization->new(
            domains => ['cdn.example.com'],
            clock   => sub { $NOW },
        ),
    )->to_app;

    my $response = $app->(env(method => 'DELETE', path => "/$SHA256"));

    is($response->[0], 401, 'missing authorization status');
    my $headers = headers_hash([@{$response->[1]}]);
    is($headers->{'www-authenticate'}, 'Nostr', 'Nostr challenge header');
    is($headers->{'content-length'}, 0, 'empty error body');
    is($storage->{last_delete_blob}, undef, 'unauthorized delete does not reach storage');
};

subtest 'PSGI app maps request translation failures to 400 responses' => sub {
    my $app = Net::Blossom::Server::PSGI->new(
        server => Net::Blossom::Server->new(storage => Local::Storage->new),
    )->to_app;

    my $response = $app->(env(method => 'GET', path => "/list/$PUBKEY", query => 'limit=%XX'));

    is($response->[0], 400, 'bad query status');
    my $headers = headers_hash([@{$response->[1]}]);
    is($headers->{'x-reason'}, 'Bad Request', 'generic bad request reason');
};

subtest 'PSGI app maps typed and unexpected failures to responses' => sub {
    my $typed = Net::Blossom::Server::PSGI->new(
        server    => Net::Blossom::Server->new(storage => Local::Storage->new),
        authorize => sub {
            Net::Blossom::Server::Error->throw(status => 403, reason => 'Forbidden');
        },
    )->to_app;

    my $response = $typed->(env(method => 'GET', path => "/$SHA256"));
    is($response->[0], 403, 'typed error status');
    is(headers_hash([@{$response->[1]}])->{'x-reason'}, 'Forbidden', 'typed error reason');

    my $storage = Local::Storage->new;
    no warnings 'redefine';
    local *Local::Storage::get_blob = sub { die "backend exploded\n" };
    my $unexpected = Net::Blossom::Server::PSGI->new(
        server => Net::Blossom::Server->new(storage => $storage),
    )->to_app;

    $response = $unexpected->(env(method => 'GET', path => "/$SHA256"));
    is($response->[0], 500, 'unexpected error status');
    is(headers_hash([@{$response->[1]}])->{'x-reason'}, 'Internal Server Error',
        'unexpected error does not leak backend detail');
};

subtest 'validates constructor arguments' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);
    my $authorization = Net::Blossom::Server::Authorization->new(clock => sub { $NOW });

    like(dies { Net::Blossom::Server::PSGI->new },
        qr/server is required/, 'server required');
    like(dies { Net::Blossom::Server::PSGI->new(server => 'not a server') },
        qr/server must be a Net::Blossom::Server/, 'server class required');
    like(dies { Net::Blossom::Server::PSGI->new(server => $server, authorize => 'not code') },
        qr/authorize must be a code reference/, 'authorize coderef required');
    like(dies { Net::Blossom::Server::PSGI->new(server => $server, authorization => 'not authorization') },
        qr/authorization must be a Net::Blossom::Server::Authorization/, 'authorization class required');
    like(dies { Net::Blossom::Server::PSGI->new(server => $server, authorize => sub { }, authorization => $authorization) },
        qr/authorize and authorization are mutually exclusive/, 'authorization modes are exclusive');
    like(dies { Net::Blossom::Server::PSGI->new(server => $server, bogus => 1) },
        qr/unknown argument\(s\): bogus/, 'unknown argument rejected');
};

done_testing;
