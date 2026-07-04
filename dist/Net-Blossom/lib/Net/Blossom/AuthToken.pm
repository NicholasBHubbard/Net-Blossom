package Net::Blossom::AuthToken;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();

use Carp qw(croak);
use Class::Tiny qw(key action content expiration server servers hashes created_at);
use JSON ();
use MIME::Base64 qw(encode_base64);
use Net::Nostr::Event;

my $HEX64 = qr/\A[0-9a-f]{64}\z/;
my %ACTION = map { $_ => 1 } qw(get upload list delete media);
my $JSON = JSON->new->utf8->canonical;

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(key action content expiration server servers hashes created_at);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    croak "key is required" unless defined $args{key};
    croak "action is required" unless defined $args{action};
    croak "action must be one of get, upload, list, delete, media"
        unless $ACTION{$args{action}};
    croak "content is required" unless defined $args{content} && length $args{content};
    croak "expiration is required" unless defined $args{expiration};
    croak "expiration must be a non-negative integer"
        unless $args{expiration} =~ /\A\d+\z/;
    croak "expiration must be in the future"
        unless $args{expiration} > time;

    my @servers;
    push @servers, $args{server} if defined $args{server};
    if (defined $args{servers}) {
        croak "servers must be an array reference" unless ref($args{servers}) eq 'ARRAY';
        push @servers, @{$args{servers}};
    }
    for my $server (@servers) {
        croak "server must be a lowercase domain name"
            unless defined $server && !ref($server) && $server =~ /\A[a-z0-9.-]+\z/;
    }
    $args{servers} = \@servers;

    $args{hashes} = [] unless defined $args{hashes};
    croak "hashes must be an array reference" unless ref($args{hashes}) eq 'ARRAY';
    for my $hash (@{$args{hashes}}) {
        croak "hash must be 64-char lowercase hex"
            unless defined $hash && $hash =~ $HEX64;
    }
    croak "$args{action} authorization requires at least one hash"
        if $args{action} =~ /\A(?:upload|delete|media)\z/ && !@{$args{hashes}};

    $args{created_at} = time() unless defined $args{created_at};
    croak "created_at must be a non-negative integer"
        unless $args{created_at} =~ /\A\d+\z/;

    return bless \%args, $class;
}

sub to_event {
    my ($self) = @_;
    my @tags = (
        ['t', $self->action],
        ['expiration', '' . $self->expiration],
    );
    push @tags, map { ['server', $_] } @{$self->servers};
    push @tags, map { ['x', $_] } @{$self->hashes};

    my $event = Net::Nostr::Event->new(
        pubkey     => $self->key->pubkey_hex,
        kind       => 24242,
        created_at => $self->created_at,
        tags       => \@tags,
        content    => $self->content,
    );
    $self->key->sign_event($event);
    return $event;
}

sub authorization_header {
    my ($self) = @_;
    my $json = $JSON->encode($self->to_event->to_hash);
    my $b64 = encode_base64($json, '');
    $b64 =~ tr{+/}{-_};
    $b64 =~ s/=+\z//;
    return "Nostr $b64";
}

1;
