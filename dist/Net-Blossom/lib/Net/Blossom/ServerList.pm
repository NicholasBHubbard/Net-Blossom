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
