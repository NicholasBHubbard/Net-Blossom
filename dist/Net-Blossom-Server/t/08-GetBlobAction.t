use strictures 2;

use Test::More;
use JSON ();

use Net::Blossom::BlobDescriptor;
use Net::Blossom::Server;
use Net::Blossom::Server::Request;

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
        return bless { blobs => $args{blobs} || {} }, $class;
    }

    sub begin_upload {
        return Local::Upload->new;
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

    sub last_get_blob {
        my ($self) = @_;
        return $self->{last_get_blob};
    }
}

{
    package Local::Upload;
    use strictures 2;

    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }

    sub write {
        return length $_[1];
    }

    sub commit {
        return;
    }

    sub abort {
        return 1;
    }
}

sub request {
    my (%args) = @_;
    return Net::Blossom::Server::Request->new(
        method => $args{method},
        path   => $args{path},
    );
}

sub descriptor {
    return Net::Blossom::BlobDescriptor->new(
        url      => "https://cdn.example.com/$SHA256",
        sha256   => $SHA256,
        size     => 12,
        type     => 'text/plain',
        uploaded => 1725105921,
        extra    => { alt => 'https://mirror.example.com/blob' },
    );
}

subtest 'handle_get_blob returns descriptor JSON' => sub {
    my $descriptor = descriptor();
    my $storage = Local::Storage->new(blobs => { $SHA256 => $descriptor });
    my $server = Net::Blossom::Server->new(storage => $storage);

    my $response = $server->handle_get_blob(request(method => 'GET', path => "/$SHA256"));

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 200, 'descriptor status');
    is($response->header('content-type'), 'application/json', 'json content type');
    is_deeply($JSON->decode($response->body), $descriptor->to_hash, 'descriptor body');
    is($storage->last_get_blob, $SHA256, 'sha256 passed to storage');
};

subtest 'handle_get_blob returns 404 when storage has no descriptor' => sub {
    my $storage = Local::Storage->new;
    my $server = Net::Blossom::Server->new(storage => $storage);

    my $response = $server->handle_get_blob(request(method => 'GET', path => "/$SHA256"));

    isa_ok($response, 'Net::Blossom::Server::Response');
    is($response->status, 404, 'missing descriptor status');
    is($response->body, '', 'missing descriptor body');
    is($response->header('content-length'), 0, 'missing descriptor content length');
    is($storage->last_get_blob, $SHA256, 'missing sha256 passed to storage');
};

subtest 'handle_get_blob validates request inputs' => sub {
    my $server = Net::Blossom::Server->new(storage => Local::Storage->new);

    like(dies { $server->handle_get_blob('not a request') },
        qr/request must be a Net::Blossom::Server::Request/, 'request object required');
    like(dies { $server->handle_get_blob(request(method => 'POST', path => "/$SHA256")) },
        qr/blob request method must be GET/, 'method rejected');
    like(dies { $server->handle_get_blob(request(method => 'GET', path => '/missing')) },
        qr/blob request path must be \/<sha256>/, 'path shape rejected');
    like(dies { $server->handle_get_blob(request(method => 'GET', path => '/' . uc($SHA256))) },
        qr/sha256 must be 64-char lowercase hex/, 'uppercase hash rejected');
    like(dies { $server->handle_get_blob(request(method => 'GET', path => "/$SHA256"), bogus => 1) },
        qr/unknown option\(s\): bogus/, 'unknown option rejected');
};

subtest 'handle_get_blob rejects invalid storage descriptors' => sub {
    my $storage = Local::Storage->new(blobs => { $SHA256 => { sha256 => $SHA256 } });
    my $server = Net::Blossom::Server->new(storage => $storage);

    like(dies { $server->handle_get_blob(request(method => 'GET', path => "/$SHA256")) },
        qr/storage get_blob must return a Net::Blossom::BlobDescriptor/,
        'storage descriptor class required');

    my $other = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    my $bad_descriptor = Net::Blossom::BlobDescriptor->new(
        url      => "https://cdn.example.com/$other",
        sha256   => $other,
        size     => 12,
        type     => 'text/plain',
        uploaded => 1725105921,
    );
    $storage = Local::Storage->new(blobs => { $SHA256 => $bad_descriptor });
    $server = Net::Blossom::Server->new(storage => $storage);

    like(dies { $server->handle_get_blob(request(method => 'GET', path => "/$SHA256")) },
        qr/storage returned descriptor sha256 mismatch/,
        'storage descriptor hash must match request path');
};

done_testing;
