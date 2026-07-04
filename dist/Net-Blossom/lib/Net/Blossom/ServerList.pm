package Net::Blossom::ServerList;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();

use Carp qw(croak);
use Class::Tiny qw(_servers);
use Net::Nostr::Event;

my $KIND  = 10063;
my $HEX64 = qr/[0-9A-Fa-f]{64}/;

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(servers);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    croak "servers is required" unless exists $args{servers};
    croak "servers must be an array reference" unless ref($args{servers}) eq 'ARRAY';
    my @servers = @{$args{servers}};
    croak "server list requires at least one server" unless @servers;

    for my $server (@servers) {
        croak "server must be an http(s) base URL"
            unless defined $server && !ref($server) && _valid_server_url($server);
    }

    return bless { _servers => \@servers }, $class;
}

sub from_event {
    my ($class, $event) = @_;
    croak "event is required" unless defined $event;

    my $kind = _event_field($event, 'kind');
    croak "event must be kind 10063"
        unless defined $kind && $kind =~ /\A\d+\z/ && $kind == $KIND;

    my $tags = _event_field($event, 'tags');
    croak "event tags must be an array reference" unless ref($tags) eq 'ARRAY';

    my @servers;
    for my $tag (@$tags) {
        croak "each event tag must be an array reference" unless ref($tag) eq 'ARRAY';
        next unless defined $tag->[0] && $tag->[0] eq 'server';
        croak "server tag must include URL" unless defined $tag->[1] && length $tag->[1];
        push @servers, $tag->[1];
    }

    return $class->new(servers => \@servers);
}

sub servers {
    my ($self) = @_;
    return [@{$self->_servers}];
}

sub primary_server {
    my ($self) = @_;
    return $self->_servers->[0];
}

sub to_tags {
    my ($self) = @_;
    return [map { ['server', $_] } @{$self->_servers}];
}

sub to_event {
    my $self = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    return Net::Nostr::Event->new(
        %args,
        kind    => $KIND,
        content => '',
        tags    => $self->to_tags,
    );
}

sub extract_sha256 {
    my $class = shift;
    my ($sha256) = $class->extract_blob_reference(@_);
    return $sha256;
}

sub extract_blob_reference {
    my ($class, $url) = @_;
    return unless defined $url && length $url;

    my ($sha256, $end);
    while ($url =~ /(?:\A|[^0-9A-Fa-f])($HEX64)(?![0-9A-Fa-f])/g) {
        $sha256 = lc $1;
        $end = pos($url);
    }
    return unless defined $sha256;

    my $extension;
    my $tail = substr($url, $end);
    $extension = $1 if $tail =~ /\A\.([A-Za-z0-9]+)(?:[?#].*)?\z/;
    return ($sha256, $extension);
}

sub blob_urls_for {
    my ($self, $url) = @_;
    my ($sha256, $extension) = $self->extract_blob_reference($url);
    return [] unless defined $sha256;

    my $path = $sha256;
    $path .= ".$extension" if defined $extension;

    return [map {
        my $server = $_;
        $server =~ s{/+\z}{};
        "$server/$path";
    } @{$self->_servers}];
}

sub _event_field {
    my ($event, $field) = @_;
    return $event->{$field} if ref($event) eq 'HASH';
    croak "event must be a hash reference or object" unless ref($event);
    croak "event object must provide $field" unless $event->can($field);
    return $event->$field;
}

sub _valid_server_url {
    my ($server) = @_;
    return $server =~ m{\Ahttps?://[^\s/?#@]+(?:/[^\s?#]*)?\z};
}

1;

=pod

=head1 NAME

Net::Blossom::ServerList - BUD-03 Blossom server-list value object

=head1 SYNOPSIS

    use Net::Blossom::ServerList;

    my $list = Net::Blossom::ServerList->new(
        servers => [
            'https://cdn.example.com',
            'https://backup.example.com',
        ],
    );

    my $servers = $list->servers;

=head1 DESCRIPTION

C<Net::Blossom::ServerList> represents a user's BUD-03 list of Blossom servers.
Server order is preserved. The first server is treated as primary by helper
methods.

=head1 CONSTRUCTORS

=head2 new

    my $list = Net::Blossom::ServerList->new(servers => \@servers);

Creates a server list from an array reference of HTTP or HTTPS base URLs. At
least one server is required. Unknown arguments or invalid server URLs croak.

=head2 from_event

    my $list = Net::Blossom::ServerList->from_event($event);

Builds a server list from a kind C<10063> event hash reference or event-like
object. The event must provide C<kind> and C<tags>. C<server> tags are read in
order.

=head1 METHODS

=head2 servers

    my $servers = $list->servers;

Returns a copy array reference of server base URLs. Mutating the returned array
reference does not mutate the object.

=head2 primary_server

    my $server = $list->primary_server;

Returns the first listed server.

=head2 to_tags

    my $tags = $list->to_tags;

Returns a Nostr tag array reference containing one C<server> tag per server.

=head2 to_event

    my $event = $list->to_event(%event_args);

Returns a C<Net::Nostr::Event> for kind C<10063>. Arguments are passed through
to C<Net::Nostr::Event-E<gt>new>; C<kind>, C<content>, and C<tags> are supplied
by the server list.

=head2 extract_sha256

    my $sha256 = Net::Blossom::ServerList->extract_sha256($url);

Extracts and returns the last 64-character hex SHA-256 value from C<$url>,
normalized to lowercase. Returns C<undef> when no hash is found.

=head2 extract_blob_reference

    my ($sha256, $extension) =
        Net::Blossom::ServerList->extract_blob_reference($url);

Extracts the last SHA-256 hash and an optional alphanumeric extension. Returns
an empty list when no hash is found.

=head2 blob_urls_for

    my $urls = $list->blob_urls_for($url);

Builds fallback blob URLs for every server in the list using the hash and
optional extension extracted from C<$url>. Returns an array reference. Returns an
empty array reference when C<$url> does not contain a hash.

=cut
