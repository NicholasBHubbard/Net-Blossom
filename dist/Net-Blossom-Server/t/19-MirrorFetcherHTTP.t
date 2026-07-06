use strictures 2;

use Test::More;

use Net::Blossom::Server::Error;
use Net::Blossom::Server::MirrorFetcher::HTTP;

sub dies(&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

{
    package Local::UA;
    use strictures 2;

    sub new {
        my ($class, %args) = @_;
        return bless { requests => [], %args }, $class;
    }

    sub request {
        my ($self, $method, $url, $opts) = @_;
        push @{$self->{requests}}, [$method, $url, $opts];
        die "request failed" if $self->{die};

        my $response = $self->{response} || {
            success => 1,
            status  => 200,
            reason  => 'OK',
            headers => {},
            content => '',
        };

        if (exists $response->{body_chunks}) {
            for my $chunk (@{$response->{body_chunks}}) {
                $opts->{data_callback}->($chunk);
            }
        }
        elsif (exists $response->{content} && ref($opts) eq 'HASH' && $opts->{data_callback}) {
            $opts->{data_callback}->($response->{content});
        }

        return $response;
    }

    sub requests {
        my ($self) = @_;
        return @{$self->{requests}};
    }
}

sub error_status(&) {
    my ($code) = @_;
    my $error = dies { $code->() };
    isa_ok($error, 'Net::Blossom::Server::Error');
    return $error->status;
}

subtest 'constructs allowlist-only HTTP mirror fetcher' => sub {
    my $ua = Local::UA->new;
    my $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['CDN.Example', 'media.example'],
        max_bytes     => 1024,
        timeout       => 3,
        user_agent    => $ua,
    );

    isa_ok($fetcher, 'Net::Blossom::Server::MirrorFetcher::HTTP');
    is_deeply($fetcher->allowed_hosts, ['cdn.example', 'media.example'], 'hosts normalized');
    is($fetcher->max_bytes, 1024, 'max bytes accessor');
    is($fetcher->timeout, 3, 'timeout accessor');
    is($fetcher->user_agent, $ua, 'user agent accessor');

    my $hosts = $fetcher->allowed_hosts;
    push @$hosts, 'mutated.example';
    is_deeply($fetcher->allowed_hosts, ['cdn.example', 'media.example'], 'allowed_hosts does not alias');
};

subtest 'validates constructor policy' => sub {
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(max_bytes => 1024) },
        qr/allowed_hosts is required/, 'allowed_hosts required');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => [], max_bytes => 1024) },
        qr/allowed_hosts must not be empty/, 'allowed_hosts cannot be empty');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => ['https://cdn.example'], max_bytes => 1024) },
        qr/allowed_hosts must contain host names only/, 'allowed_hosts rejects URLs');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => ['cdn.example']) },
        qr/max_bytes is required/, 'max_bytes required');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => ['cdn.example'], max_bytes => 0) },
        qr/max_bytes must be a positive integer/, 'max_bytes positive');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => ['cdn.example'], max_bytes => 1024, timeout => 0) },
        qr/timeout must be a positive integer/, 'timeout positive');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => ['cdn.example'], max_bytes => 1024, user_agent => bless {}, 'Local::NoRequest') },
        qr/user_agent must provide request/, 'user agent contract required');
    like(dies { Net::Blossom::Server::MirrorFetcher::HTTP->new(allowed_hosts => ['cdn.example'], max_bytes => 1024, bogus => 1) },
        qr/unknown argument\(s\): bogus/, 'unknown arguments rejected');
};

subtest 'fetch_blob accepts only allowed HTTP URLs' => sub {
    my $ua = Local::UA->new(response => {
        success => 1,
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'text/plain', 'content-length' => 4 },
        content => 'body',
    });
    my $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 1024,
        user_agent    => $ua,
    );

    my $result = $fetcher->fetch_blob('https://cdn.example/path/blob.txt?download=1');
    is_deeply($result, {
        body           => 'body',
        type           => 'text/plain',
        content_length => 4,
    }, 'allowed URL returns body metadata');

    my ($request) = $ua->requests;
    is($request->[0], 'GET', 'uses GET');
    is($request->[1], 'https://cdn.example/path/blob.txt?download=1', 'request URL');
    is(ref($request->[2]{data_callback}), 'CODE', 'streams through data_callback');

    is(error_status { $fetcher->fetch_blob('ftp://cdn.example/blob.bin') },
        400, 'non-http URL rejected');
    is(error_status { $fetcher->fetch_blob('https://user:pass@cdn.example/blob.bin') },
        400, 'userinfo URL rejected');
    is(error_status { $fetcher->fetch_blob('https://cdn.example/blob.bin#frag') },
        400, 'fragment URL rejected');
    is(error_status { $fetcher->fetch_blob('https://blocked.example/blob.bin') },
        403, 'non-allowlisted host rejected');
};

subtest 'fetch_blob rejects non-default ports on allowed hosts' => sub {
    my $ua = Local::UA->new(response => {
        success => 1,
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'text/plain', 'content-length' => 4 },
        content => 'body',
    });
    my $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 1024,
        user_agent    => $ua,
    );

    # An allowlisted host name must not become a way to reach arbitrary ports
    # (e.g. internal services co-located on that host).
    is(error_status { $fetcher->fetch_blob('http://cdn.example:22/blob.bin') },
        403, 'non-default http port rejected');
    is(error_status { $fetcher->fetch_blob('https://cdn.example:8443/blob.bin') },
        403, 'non-default https port rejected');

    # The scheme default port, explicit or implicit, is allowed.
    ok($fetcher->fetch_blob('https://cdn.example/blob.txt'), 'implicit default port allowed');
    ok($fetcher->fetch_blob('https://cdn.example:443/blob.txt'), 'explicit default https port allowed');
    ok($fetcher->fetch_blob('http://cdn.example:80/blob.txt'), 'explicit default http port allowed');
};

subtest 'fetch_blob rejects redirects and origin failures' => sub {
    my $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 1024,
        user_agent    => Local::UA->new(response => {
            success => 0,
            status  => 302,
            reason  => 'Found',
            headers => { location => 'https://other.example/blob.bin' },
            content => '',
        }),
    );

    is(error_status { $fetcher->fetch_blob('https://cdn.example/blob.bin') },
        502, 'redirect response rejected');

    $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 1024,
        user_agent    => Local::UA->new(die => 1),
    );
    is(error_status { $fetcher->fetch_blob('https://cdn.example/blob.bin') },
        502, 'client exception rejected');
};

subtest 'fetch_blob enforces response size limits' => sub {
    my $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 4,
        user_agent    => Local::UA->new(response => {
            success => 1,
            status  => 200,
            reason  => 'OK',
            headers => { 'content-length' => 5 },
            content => 'hello',
        }),
    );

    is(error_status { $fetcher->fetch_blob('https://cdn.example/blob.bin') },
        413, 'Content-Length over max rejected');

    $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 4,
        user_agent    => Local::UA->new(response => {
            success     => 1,
            status      => 200,
            reason      => 'OK',
            headers     => {},
            body_chunks => ['he', 'llo'],
        }),
    );

    is(error_status { $fetcher->fetch_blob('https://cdn.example/blob.bin') },
        413, 'stream over max rejected');
};

subtest 'fetch_blob defaults content type and rejects bad metadata' => sub {
    my $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 1024,
        user_agent    => Local::UA->new(response => {
            success => 1,
            status  => 200,
            reason  => 'OK',
            headers => {},
            content => 'body',
        }),
    );

    is_deeply($fetcher->fetch_blob('https://cdn.example/blob.bin'), {
        body => 'body',
        type => 'application/octet-stream',
    }, 'missing content type defaults');

    $fetcher = Net::Blossom::Server::MirrorFetcher::HTTP->new(
        allowed_hosts => ['cdn.example'],
        max_bytes     => 1024,
        user_agent    => Local::UA->new(response => {
            success => 1,
            status  => 200,
            reason  => 'OK',
            headers => { 'content-length' => 'abc' },
            content => 'body',
        }),
    );

    is(error_status { $fetcher->fetch_blob('https://cdn.example/blob.bin') },
        502, 'invalid Content-Length rejected');
};

done_testing;
