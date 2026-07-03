use strictures 2;

use Test::More;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

use Net::Blossom::Client;

sub dies(&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

{
    package Local::UA;
    use strictures 2;
    sub new { bless { requests => [], responses => [@_[1 .. $#_]] }, $_[0] }
    sub request {
        my ($self, $method, $url, $opts) = @_;
        push @{$self->{requests}}, [$method, $url, $opts || {}];
        return shift @{$self->{responses}};
    }
    sub requests { @{$_[0]->{requests}} }
}

my $HASH = 'b1674191a88ec5cdd733e4240a81803105dc412d6c6708d53ab94fc248f4f553';
my $JSON = JSON::PP->new->utf8->canonical;

sub descriptor {
    return {
        url      => "https://cdn.example.com/$HASH.bin",
        sha256   => $HASH,
        size     => 12,
        type     => 'application/octet-stream',
        uploaded => 1725105921,
    };
}

subtest 'BUD-07 402 responses croak as PaymentRequired with payment challenges' => sub {
    my $ua = Local::UA->new({
        status  => 402,
        reason  => 'Payment Required',
        headers => {
            'X-Cashu'     => 'creqApWF0gaNh...',
            'x-lightning' => 'lnbc30n1pnnmw3...',
            'X-Fedimint'  => 'future-method-payload',
            'X-Reason'    => 'payment required for upload',
        },
        content => 'pay first',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $error = dies { $client->upload_blob('paid bytes') };
    isa_ok($error, 'Net::Blossom::PaymentRequired');
    isa_ok($error, 'Net::Blossom::Error');
    is($error->status, 402, 'status');
    is($error->x_reason, 'payment required for upload', 'x-reason diagnostic');
    is_deeply([$error->payment_methods], [qw(cashu fedimint lightning)], 'payment methods parsed');
    is($error->payment_challenge('cashu'), 'creqApWF0gaNh...', 'cashu challenge');
    is($error->payment_challenge('lightning'), 'lnbc30n1pnnmw3...', 'lightning challenge');
    is($error->payment_challenge('x-fedimint'), 'future-method-payload', 'future method challenge');
    is($error->payment_challenge('reason'), undef, 'x-reason is not a payment method');
    like("$error", qr/402 Payment Required: payment required for upload/, 'stringifies usefully');
};

subtest 'BUD-07 payment proof headers can be supplied when retrying body endpoints' => sub {
    my $body = 'paid bytes';
    my $ua = Local::UA->new({
        status  => 201,
        reason  => 'Created',
        headers => { 'content-type' => 'application/json' },
        content => $JSON->encode(descriptor()),
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $blob = $client->upload_blob(
        $body,
        payment => {
            cashu       => 'cashuBo2F0gqJhaUgA',
            lightning   => '966fcb8f153339372f9a187f725384ff4ceae0047c25b9ce607488d7c7e93bba',
            'fedimint'  => 'future-proof',
        },
    );
    is($blob->sha256, $HASH, 'descriptor parsed after paid retry');

    my ($method, $url, $opts) = @{($ua->requests)[0]};
    is($method, 'PUT', 'PUT retry');
    is($url, 'https://cdn.example.com/upload', 'upload endpoint');
    is($opts->{headers}{'X-Cashu'}, 'cashuBo2F0gqJhaUgA', 'cashu proof header');
    is($opts->{headers}{'X-Lightning'}, '966fcb8f153339372f9a187f725384ff4ceae0047c25b9ce607488d7c7e93bba', 'lightning proof header');
    is($opts->{headers}{'X-Fedimint'}, 'future-proof', 'future method proof header');
    is($opts->{headers}{'X-SHA-256'}, sha256_hex($body), 'upload hash still sent');
};

subtest 'BUD-07 HEAD preflights expose payment challenges but are not retried with payment proof' => sub {
    my $ua = Local::UA->new({
        status  => 402,
        reason  => 'Payment Required',
        headers => { 'X-Cashu' => 'creq-upload', 'X-Reason' => 'pay before upload' },
        content => '',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $error = dies { $client->head_upload('paid bytes') };
    isa_ok($error, 'Net::Blossom::PaymentRequired');
    is($error->payment_challenge('cashu'), 'creq-upload', 'preflight challenge exposed');

    my $retry_error = dies {
        $client->head_upload('paid bytes', payment => { cashu => 'cashuBo2F0gqJhaUgA' });
    };
    like($retry_error, qr/payment proof headers are not allowed on HEAD requests/, 'HEAD proof retry rejected');
    is(scalar $ua->requests, 1, 'rejected HEAD retry is not sent');
};

subtest 'BUD-07 payment proof headers can be supplied when retrying GET downloads' => sub {
    my $ua = Local::UA->new({
        status  => 200,
        reason  => 'OK',
        headers => { 'content-type' => 'application/octet-stream' },
        content => 'blob',
    });
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => $ua);

    my $response = $client->get_blob($HASH, payment => { 'X-Lightning' => 'download-preimage' });
    is($response->content, 'blob', 'download response');

    my ($method, $url, $opts) = @{($ua->requests)[0]};
    is($method, 'GET', 'GET retry');
    is($url, "https://cdn.example.com/$HASH", 'blob endpoint');
    is($opts->{headers}{'X-Lightning'}, 'download-preimage', 'payment proof header');
};

subtest 'BUD-07 payment proof inputs are validated locally' => sub {
    my $client = Net::Blossom::Client->new(server => 'https://cdn.example.com', ua => Local::UA->new);

    like(dies { $client->get_blob($HASH, payment => 'cashuBo') },
        qr/payment must be a hash reference/, 'payment hashref required');
    like(dies { $client->get_blob($HASH, payment => { '' => 'cashuBo' }) },
        qr/payment method is required/, 'payment method required');
    like(dies { $client->get_blob($HASH, payment => { 'bad method' => 'cashuBo' }) },
        qr/payment method must be an X- header token/, 'payment method token validated');
    like(dies { $client->get_blob($HASH, payment => { cashu => '' }) },
        qr/payment proof for cashu is required/, 'payment proof required');
    like(dies { $client->get_blob($HASH, payment => { cashu => [] }) },
        qr/payment proof for cashu must be a scalar/, 'payment proof scalar required');
    like(dies { $client->get_blob($HASH, payment => { reason => 'not a proof' }) },
        qr/payment method reason is reserved/, 'reserved X-Reason rejected');
};

done_testing;
