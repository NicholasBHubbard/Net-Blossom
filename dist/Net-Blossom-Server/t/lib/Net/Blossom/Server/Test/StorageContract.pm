package Net::Blossom::Server::Test::StorageContract;

use strictures 2;

use Carp qw(croak);
use Digest::SHA qw(sha256_hex);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use Test::More ();

use Net::Blossom::BlobDescriptor;
use Net::Blossom::Server;
use Net::Blossom::Server::Storage;
use Net::Blossom::Server::UploadResult;

our @EXPORT_OK = qw(storage_contract_ok);

my $PUBKEY = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
my $OTHER_PUBKEY = '266815e0c9210dfa324c6cba3573b14bee49da4209a9456f9484e5106cd408a5';

sub storage_contract_ok {
    my %args = @_;
    my $name = delete $args{name};
    my $factory = delete $args{storage};
    croak "unknown argument(s): " . join(', ', sort keys %args) if keys %args;
    croak "name is required" unless defined $name && !ref($name) && length $name;
    croak "storage must be a code reference" unless ref($factory) eq 'CODE';

    Test::More::subtest $name => sub {
        _committed_uploads_are_visible($factory);
        _failed_uploads_are_not_visible($factory);
        _delete_hides_blob($factory);
        _delete_is_pubkey_scoped($factory);
    };

    return 1;
}

sub _committed_uploads_are_visible {
    my ($factory) = @_;
    my $storage = _fresh_storage($factory);
    my $server = Net::Blossom::Server->new(storage => $storage, clock => sub { 1725105921 });
    my $body = "contract blob one\n";
    my $sha256 = sha256_hex($body);

    my $result = $server->receive_blob(
        $body,
        type            => 'text/plain',
        expected_sha256 => $sha256,
        content_length  => length($body),
        pubkey          => $PUBKEY,
    );

    _is_upload_result($result, 1, 'new upload result');
    my $blob = $result->descriptor;
    _is_descriptor($blob, $sha256, length($body), 'text/plain', 1725105921, 'upload descriptor');
    _is_descriptor($storage->get_blob($sha256), $sha256, length($body), 'text/plain', 1725105921, 'get_blob descriptor');

    my $second = _upload($storage, "contract blob two\n", 1725105922);
    my $listed = $storage->list_blobs($PUBKEY);
    _is_descriptor_list($listed, [$second->descriptor->sha256, $sha256], 'list_blobs returns uploaded-desc order');

    my $page = $storage->list_blobs($PUBKEY, cursor => $second->descriptor->sha256, limit => 1);
    _is_descriptor_list($page, [$sha256], 'list_blobs supports cursor and limit');

    my $empty = $storage->list_blobs($OTHER_PUBKEY);
    _is_descriptor_list($empty, [], 'list_blobs scopes by pubkey');

    my $duplicate = _upload($storage, $body, 1725105923);
    _is_upload_result($duplicate, 0, 'duplicate upload result');
    $listed = $storage->list_blobs($PUBKEY);
    my @same = grep { $_->sha256 eq $sha256 } @$listed;
    Test::More::is(scalar @same, 1, 'duplicate upload is visible once for the same pubkey');
}

sub _failed_uploads_are_not_visible {
    my ($factory) = @_;
    my $storage = _fresh_storage($factory);
    my $server = Net::Blossom::Server->new(storage => $storage, clock => sub { 1725105921 });
    my $body = "bad contract blob\n";
    my $sha256 = sha256_hex($body);

    my $ok = eval {
        $server->receive_blob($body, expected_sha256 => '0' x 64, pubkey => $PUBKEY);
        1;
    };

    Test::More::ok(!$ok, 'failed upload croaks');
    Test::More::like($@, qr/sha256 mismatch/, 'failed upload reports sha mismatch');
    Test::More::is($storage->get_blob($sha256), undef, 'failed upload is not retrievable');
    _is_descriptor_list($storage->list_blobs($PUBKEY), [], 'failed upload is not listed');
}

sub _delete_hides_blob {
    my ($factory) = @_;
    my $storage = _fresh_storage($factory);
    my $blob = _upload($storage, "delete contract blob\n", 1725105921)->descriptor;

    Test::More::ok($storage->delete_blob($blob->sha256, pubkey => $PUBKEY), 'delete_blob returns true for existing blob');
    Test::More::is($storage->get_blob($blob->sha256), undef, 'deleted blob is not retrievable');
    _is_descriptor_list($storage->list_blobs($PUBKEY), [], 'deleted blob is not listed');
    Test::More::ok(!$storage->delete_blob($blob->sha256, pubkey => $PUBKEY), 'delete_blob returns false for missing blob');
}

sub _delete_is_pubkey_scoped {
    my ($factory) = @_;
    my $storage = _fresh_storage($factory);
    my $body = "shared contract blob\n";
    my $first = _upload($storage, $body, 1725105921, $PUBKEY);
    my $second = _upload($storage, $body, 1725105922, $OTHER_PUBKEY);
    my $sha256 = $first->descriptor->sha256;

    _is_upload_result($first, 1, 'first shared upload result');
    _is_upload_result($second, 0, 'second shared upload result');
    Test::More::is($second->descriptor->sha256, $sha256, 'same bytes produce same hash for another pubkey');
    Test::More::ok($storage->delete_blob($sha256, pubkey => $PUBKEY), 'delete_blob removes one owner');
    Test::More::isa_ok($storage->get_blob($sha256), 'Net::Blossom::BlobDescriptor', 'shared blob remains retrievable');
    _is_descriptor_list($storage->list_blobs($PUBKEY), [], 'deleted owner no longer lists shared blob');
    _is_descriptor_list($storage->list_blobs($OTHER_PUBKEY), [$sha256], 'other owner still lists shared blob');
    Test::More::ok($storage->delete_blob($sha256, pubkey => $OTHER_PUBKEY), 'delete_blob removes final owner');
    Test::More::is($storage->get_blob($sha256), undef, 'shared blob is removed after final owner delete');
}

sub _upload {
    my ($storage, $body, $uploaded, $pubkey) = @_;
    $pubkey = $PUBKEY unless defined $pubkey;
    my $server = Net::Blossom::Server->new(storage => $storage, clock => sub { $uploaded });
    return $server->receive_blob(
        $body,
        type           => 'application/octet-stream',
        content_length => length($body),
        pubkey         => $pubkey,
    );
}

sub _fresh_storage {
    my ($factory) = @_;
    my $storage = $factory->();
    Net::Blossom::Server::Storage->assert_implements($storage);
    return $storage;
}

sub _is_descriptor {
    my ($descriptor, $sha256, $size, $type, $uploaded, $name) = @_;
    Test::More::isa_ok($descriptor, 'Net::Blossom::BlobDescriptor', $name);
    return unless blessed($descriptor) && $descriptor->isa('Net::Blossom::BlobDescriptor');
    Test::More::is($descriptor->sha256, $sha256, "$name sha256");
    Test::More::is($descriptor->size, $size, "$name size");
    Test::More::is($descriptor->type, $type, "$name type");
    Test::More::is($descriptor->uploaded, $uploaded, "$name uploaded");
}

sub _is_upload_result {
    my ($result, $created, $name) = @_;
    Test::More::isa_ok($result, 'Net::Blossom::Server::UploadResult', $name);
    return unless blessed($result) && $result->isa('Net::Blossom::Server::UploadResult');
    Test::More::isa_ok($result->descriptor, 'Net::Blossom::BlobDescriptor', "$name descriptor");
    Test::More::is($result->created, $created, "$name created");
}

sub _is_descriptor_list {
    my ($list, $sha256, $name) = @_;
    Test::More::is(ref($list), 'ARRAY', "$name returns array reference");
    return unless ref($list) eq 'ARRAY';
    my @got;
    for my $descriptor (@$list) {
        Test::More::isa_ok($descriptor, 'Net::Blossom::BlobDescriptor', "$name item");
        push @got, blessed($descriptor) && $descriptor->isa('Net::Blossom::BlobDescriptor')
            ? $descriptor->sha256
            : undef;
    }
    Test::More::is_deeply(\@got, $sha256, $name);
}

1;
