use strictures 2;

use Test::More;
use Digest::SHA qw(sha256_hex);
use JSON ();

use Net::Blossom::BlobDescriptor;
use Net::Blossom::Server;
use Net::Blossom::Server::Request;

my $PUBKEY = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
my $SHA256 = '0f343b0931126a20f133d67c2b018a3b5ceca63dd3585a76cb1f3289a274707f';
my $JSON = JSON->new->utf8->canonical;

sub dies(&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

{
    package Local::Storage;
    use strictures 2;

    sub new {
        my ($class, %args) = @_;
        return bless { uploads => [], blobs => $args{blobs} || {} }, $class;
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
        return 0;
    }

    sub list_blobs {
        return [];
    }

    sub uploads {
        my ($self) = @_;
        return @{$self->{uploads}};
    }

    sub last_get_blob {
        my ($self) = @_;
        return $self->{last_get_blob};
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
        my ($self) = @_;
        $self->{aborted}++;
        return 1;
    }
}

sub request {
    my (%args) = @_;
    return Net::Blossom::Server::Request->new(
        method         => $args{method},
        path           => $args{path},
        body           => $args{body},
        content_type   => $args{content_type},
        content_length => $args{content_length},
    );
}

subtest 'handle_request dispatches PUT /upload' => sub {
    my $storage = Local::Storage->new;
    my $server = Net::Blossom::Server->new(storage => $storage, clock => sub { 1725105921 });
    my $body = "dispatch body\n";

    my $response = $server->handle_request(
        request(
            method         => 'PUT',
            path           => '/upload',
            body           => $body,
            content_type   => 'text/plain',
            content_length => length($body),
        ),
        pubkey => $PUBKEY,
    );

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 201, 'upload status');
    is($JSON->decode($response->body)->{sha256}, sha256_hex($body), 'upload descriptor response');

    my ($upload) = $storage->uploads;
    is($upload->{context}{pubkey}, $PUBKEY, 'pubkey passed to upload handler');
    is_deeply($upload->{chunks}, [$body], 'body reached storage');
};

subtest 'handle_request dispatches GET /<sha256>' => sub {
    my $descriptor = Net::Blossom::BlobDescriptor->new(
        url      => "https://cdn.example.com/$SHA256",
        sha256   => $SHA256,
        size     => 12,
        type     => 'text/plain',
        uploaded => 1725105921,
    );
    my $storage = Local::Storage->new(blobs => { $SHA256 => $descriptor });
    my $server = Net::Blossom::Server->new(storage => $storage);

    my $response = $server->handle_request(request(method => 'GET', path => "/$SHA256"));

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 200, 'get blob status');
    is_deeply($JSON->decode($response->body), $descriptor->to_hash, 'get blob descriptor response');
    is($storage->last_get_blob, $SHA256, 'sha256 passed to storage');
};

subtest 'handle_request returns 404 for unknown paths' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);

    my $response = $server->handle_request(request(method => 'GET', path => '/missing'));

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 404, 'unknown path status');
    is($response->body, '', 'unknown path body');
    is($response->header('content-length'), 0, 'unknown path content length');
};

subtest 'handle_request treats uppercase blob paths as unknown' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);
    my $response;

    is(dies { $response = $server->handle_request(request(method => 'GET', path => '/' . uc($SHA256))) },
        undef, 'uppercase blob path does not croak');
    if (isa_ok($response, 'Net::Blossom::Server::Response')) {
        is($response->status, 404, 'uppercase blob path status');
        is($response->body, '', 'uppercase blob path body');
    }
};

subtest 'handle_request returns 405 for unsupported upload methods' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);

    my $response = $server->handle_request(request(method => 'GET', path => '/upload'));

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 405, 'unsupported method status');
    is($response->header('allow'), 'PUT', 'allow header');
    is($response->body, '', 'unsupported method body');
};

subtest 'handle_request returns 405 for unsupported blob methods' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);

    my $response = $server->handle_request(request(method => 'POST', path => "/$SHA256"));

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 405, 'unsupported method status');
    is($response->header('allow'), 'GET', 'allow header');
    is($response->body, '', 'unsupported method body');
};

subtest 'handle_request validates inputs' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);

    like(dies { $server->handle_request('not a request') },
        qr/request must be a Net::Blossom::Server::Request/, 'request object required');
    like(dies { $server->handle_request(request(method => 'GET', path => '/missing'), bogus => 1) },
        qr/unknown option\(s\): bogus/, 'unknown option rejected');
};

done_testing;
