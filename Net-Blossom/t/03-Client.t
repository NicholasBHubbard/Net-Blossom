use strictures 2;

use Test::More;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

use Net::Blossom::Client;
use Net::Blossom::Error;

sub dies(&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

{
    package Local::UA;
    use strictures 2;

    sub new {
        my ($class, @responses) = @_;
        return bless { responses => \@responses, requests => [] }, $class;
    }

    sub request {
        my ($self, $method, $url, $opts) = @_;
        push @{$self->{requests}}, [$method, $url, $opts || {}];
        return shift @{$self->{responses}};
    }

    sub requests {
        my ($self) = @_;
        return @{$self->{requests}};
    }
}

my $HASH = 'b1674191a88ec5cdd733e4240a81803105dc412d6c6708d53ab94fc248f4f553';
my $PUBKEY = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
my $JSON = JSON::PP->new->utf8->canonical;

sub descriptor_hash {
    return {
        url      => "https://cdn.example.com/$HASH.pdf",
        sha256   => $HASH,
        size     => 184292,
        type     => 'application/pdf',
        uploaded => 1725105921,
    };
}

subtest 'constructor trims trailing server slash' => sub {
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com///');
    is($client->server, 'https://cdn.example.com', 'server normalized');
};

subtest 'GET /<sha256> returns blob response' => sub {
    my $ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'text/plain', 'content-length' => 5 },
        content => 'hello',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $response = $client->get_blob($HASH, extension => 'txt', range => 'bytes=0-4');
    is($response->status, 200, 'status');
    is($response->content, 'hello', 'content');
    is($response->header('content-type'), 'text/plain', 'content type');

    my $request = ($ua->requests)[0];
    my ($method, $url, $opts) = @$request;
    is($method, 'GET', 'GET method');
    is($url, "https://cdn.example.com/$HASH.txt", 'GET URL includes extension');
    is($opts->{headers}{Range}, 'bytes=0-4', 'Range header');
};

subtest 'HEAD /<sha256> returns metadata response' => sub {
    my $ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'application/pdf', 'content-length' => 184292 },
        content => '',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $response = $client->head_blob($HASH);
    is($response->status, 200, 'status');
    is($response->header('content-length'), 184292, 'content length');

    my $request = ($ua->requests)[0];
    my ($method, $url) = @$request;
    is($method, 'HEAD', 'HEAD method');
    is($url, "https://cdn.example.com/$HASH", 'HEAD URL');
};

subtest 'PUT /upload sends blob headers and parses descriptor' => sub {
    my $body = 'file contents';
    my $ua = Local::UA->new({
        status  => 201,
        reason  => 'Created',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode(descriptor_hash()),
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $descriptor = $client->upload_blob($body, type => 'text/plain');
    isa_ok($descriptor, 'Net::Blossom::BlobDescriptor');

    my $request = ($ua->requests)[0];
    my ($method, $url, $opts) = @$request;
    is($method, 'PUT', 'PUT method');
    is($url, 'https://cdn.example.com/upload', 'upload URL');
    is($opts->{content}, $body, 'request body');
    is($opts->{headers}{'Content-Type'}, 'text/plain', 'content type header');
    is($opts->{headers}{'Content-Length'}, length($body), 'content length header');
    is($opts->{headers}{'X-SHA-256'}, sha256_hex($body), 'sha header');
};

subtest 'PUT /upload preserves binary and empty blob bytes' => sub {
    for my $body (pack('C*', 0, 255, 10, 65), '') {
        my $ua = Local::UA->new({
            status  => 201,
            reason  => 'Created',
            headers => { 'content-type' => 'application/json' },
            content => $JSON->encode(descriptor_hash()),
        });
        my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

        $client->upload_blob($body);

        my $request = ($ua->requests)[0];
        my ($method, $url, $opts) = @$request;
        is($method, 'PUT', 'PUT method');
        is($url, 'https://cdn.example.com/upload', 'upload URL');
        is($opts->{content}, $body, 'exact request bytes');
        is($opts->{headers}{'Content-Length'}, length($body), 'byte length header');
        is($opts->{headers}{'X-SHA-256'}, sha256_hex($body), 'sha256 over exact bytes');
    }
};

subtest 'GET /list/<pubkey> parses descriptors and query params' => sub {
    my $ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode([descriptor_hash()]),
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my @blobs = $client->list_blobs($PUBKEY, cursor => $HASH, limit => 25);
    is(scalar @blobs, 1, 'one descriptor');
    isa_ok($blobs[0], 'Net::Blossom::BlobDescriptor');

    my $request = ($ua->requests)[0];
    my ($method, $url) = @$request;
    is($method, 'GET', 'GET method');
    is($url, "https://cdn.example.com/list/$PUBKEY?cursor=$HASH&limit=25", 'list URL');
};

subtest 'DELETE /<sha256> accepts 204 response' => sub {
    my $ua = Local::UA->new({
        status  => 204,
        reason  => 'No Content',
        headers => {},
        content => '',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $response = $client->delete_blob($HASH);
    is($response->status, 204, 'status');

    my $request = ($ua->requests)[0];
    my ($method, $url) = @$request;
    is($method, 'DELETE', 'DELETE method');
    is($url, "https://cdn.example.com/$HASH", 'delete URL');
};

subtest 'adds static Authorization header' => sub {
    my $ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => {},
        content => 'blob',
    });
    my $client = Net::Blossom::Client->new(
        server => 'https://cdn.example.com',
        ua     => $ua,
        auth   => 'Nostr static-token',
    );

    $client->get_blob($HASH);

    my $request = ($ua->requests)[0];
    my ($method, $url, $opts) = @$request;
    is($method, 'GET', 'GET method');
    is($url, "https://cdn.example.com/$HASH", 'GET URL');
    is($opts->{headers}{Authorization}, 'Nostr static-token', 'authorization header');
};

subtest 'passes request context to auth callback' => sub {
    my @seen;
    my $body = 'auth upload';
    my $ua = Local::UA->new({
        status  => 201,
        reason  => 'Created',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode(descriptor_hash()),
    });
    my $client = Net::Blossom::Client->new(
        server => 'https://cdn.example.com',
        ua     => $ua,
        auth   => sub {
            push @seen, { @_ };
            return 'Nostr callback-token';
        },
    );

    $client->upload_blob($body);

    is(scalar @seen, 1, 'auth callback called once');
    is($seen[0]{method}, 'PUT', 'method context');
    is($seen[0]{url}, 'https://cdn.example.com/upload', 'url context');
    is($seen[0]{action}, 'upload', 'action context');
    is($seen[0]{sha256}, sha256_hex($body), 'sha256 context');

    my $request = ($ua->requests)[0];
    my ($method, $url, $opts) = @$request;
    is($opts->{headers}{Authorization}, 'Nostr callback-token', 'callback authorization header');
};

subtest 'HTTP errors croak as Net::Blossom::Error with X-Reason' => sub {
    my $ua = Local::UA->new({
        status  => 403,
        reason  => 'Forbidden',
        headers => { 'x-reason' => 'server policy rejected this blob' },
        content => 'no',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $error = dies { $client->get_blob($HASH) };
    isa_ok($error, 'Net::Blossom::Error');
    is($error->status, 403, 'status');
    is($error->x_reason, 'server policy rejected this blob', 'x-reason');
    like("$error", qr/403 Forbidden: server policy rejected this blob/, 'stringifies usefully');
};

subtest 'malformed server JSON responses croak clearly' => sub {
    my $bad_json_ua = Local::UA->new({
        status  => 201,
        reason  => 'Created',
        headers => { 'content-type' => 'application/json' },
        content => '{',
    });
    my $bad_json_client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $bad_json_ua);
    like(dies { $bad_json_client->upload_blob('x') },
        qr/invalid JSON response/, 'invalid upload JSON rejected');

    my $array_ua = Local::UA->new({
        status  => 201,
        reason  => 'Created',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode([descriptor_hash()]),
    });
    my $array_client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $array_ua);
    like(dies { $array_client->upload_blob('x') },
        qr/response body must be a JSON object/, 'upload array response rejected');

    my $object_ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode({ blobs => [descriptor_hash()] }),
    });
    my $object_client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $object_ua);
    like(dies { $object_client->list_blobs($PUBKEY) },
        qr/list response must be a JSON array/, 'list object response rejected');

    my %descriptor = %{ descriptor_hash() };
    delete $descriptor{size};
    my $bad_descriptor_ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode([\%descriptor]),
    });
    my $bad_descriptor_client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $bad_descriptor_ua);
    like(dies { $bad_descriptor_client->list_blobs($PUBKEY) },
        qr/size is required/, 'invalid list descriptor rejected');
};

done_testing;
