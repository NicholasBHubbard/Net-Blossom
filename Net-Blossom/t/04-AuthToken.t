use strictures 2;

use Test::More;
use JSON::PP ();
use MIME::Base64 qw(decode_base64);

use Net::Blossom::AuthToken;

sub dies(&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

{
    package Local::Key;
    use strictures 2;

    sub new {
        my ($class, $pubkey) = @_;
        return bless { pubkey => $pubkey, signed => 0 }, $class;
    }

    sub pubkey_hex {
        my ($self) = @_;
        return $self->{pubkey};
    }

    sub sign_event {
        my ($self, $event) = @_;
        $self->{signed}++;
        $event->sig('b' x 128);
        return $event->sig;
    }

    sub signed {
        my ($self) = @_;
        return $self->{signed};
    }
}

my $PUBKEY = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
my $HASH = 'b1674191a88ec5cdd733e4240a81803105dc412d6c6708d53ab94fc248f4f553';

sub decode_b64url {
    my ($value) = @_;
    $value =~ tr/-_/+\//;
    $value .= '=' while length($value) % 4;
    return decode_base64($value);
}

subtest 'creates signed BUD-11 kind 24242 event' => sub {
    my $key = Local::Key->new($PUBKEY);
    my $token = Net::Blossom::AuthToken->new(
        key        => $key,
        action     => 'upload',
        content    => 'Upload Blob',
        expiration => 1772019044,
        server     => 'cdn.example.com',
        hashes     => [$HASH],
        created_at => 1708850000,
    );

    my $event = $token->to_event;
    is($event->kind, 24242, 'kind');
    is($event->pubkey, $PUBKEY, 'pubkey');
    is($event->content, 'Upload Blob', 'content');
    is($event->sig, 'b' x 128, 'signed');
    is($key->signed, 1, 'key signed event once');

    is_deeply($event->tags, [
        ['t', 'upload'],
        ['expiration', '1772019044'],
        ['server', 'cdn.example.com'],
        ['x', $HASH],
    ], 'tags');
};

subtest 'encodes Authorization header as Nostr base64url without padding' => sub {
    my $key = Local::Key->new($PUBKEY);
    my $token = Net::Blossom::AuthToken->new(
        key        => $key,
        action     => 'delete',
        content    => 'Delete Blob',
        expiration => 1772019044,
        hashes     => [$HASH],
        created_at => 1708850000,
    );

    my $header = $token->authorization_header;
    like($header, qr/\ANostr [A-Za-z0-9_-]+\z/, 'base64url Nostr header without padding');

    my ($scheme, $payload) = split / /, $header, 2;
    is($scheme, 'Nostr', 'scheme');

    my $data = JSON::PP->new->utf8->decode(decode_b64url($payload));
    is($data->{kind}, 24242, 'decoded kind');
    is($data->{tags}[0][1], 'delete', 'decoded action tag');
};

subtest 'validates BUD-11 token inputs' => sub {
    my $key = Local::Key->new($PUBKEY);

    like(dies { Net::Blossom::AuthToken->new(key => $key, action => 'bogus', content => 'x', expiration => 1) },
        qr/action/, 'unknown action rejected');
    like(dies { Net::Blossom::AuthToken->new(key => $key, action => 'upload', content => 'x', expiration => 1, server => 'https://cdn.example.com') },
        qr/server.*domain/, 'server URL rejected');
    like(dies { Net::Blossom::AuthToken->new(key => $key, action => 'upload', content => 'x', expiration => 1, hashes => ['A' x 64]) },
        qr/hash.*lowercase hex/, 'uppercase hash rejected');
};

done_testing;
