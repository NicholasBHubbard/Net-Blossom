use strictures 2;

use Test::More;

use Net::Blossom::AuthToken;

{
    package Local::Key;
    use strictures 2;
    sub new { bless { pubkey => $_[1] }, $_[0] }
    sub pubkey_hex { $_[0]->{pubkey} }
    sub sign_event { $_[1]->sig('c' x 128); $_[1]->sig }
}

my $PUBKEY = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
my $HASH = 'b1674191a88ec5cdd733e4240a81803105dc412d6c6708d53ab94fc248f4f553';

subtest 'BUD-11 authorization token uses kind 24242 and required tags' => sub {
    my $event = Net::Blossom::AuthToken->new(
        key => Local::Key->new($PUBKEY),
        action => 'upload',
        content => 'Upload Blob',
        expiration => 1772019044,
        hashes => [$HASH],
    )->to_event;

    is($event->kind, 24242, 'kind 24242');
    is_deeply($event->tags, [
        ['t', 'upload'],
        ['expiration', '1772019044'],
        ['x', $HASH],
    ], 'required tags');
};

subtest 'BUD-11 Authorization header uses Nostr scheme' => sub {
    my $header = Net::Blossom::AuthToken->new(
        key => Local::Key->new($PUBKEY),
        action => 'list',
        content => 'List Images',
        expiration => 1772019044,
    )->authorization_header;

    like($header, qr/\ANostr /, 'Nostr scheme');
};

done_testing;
