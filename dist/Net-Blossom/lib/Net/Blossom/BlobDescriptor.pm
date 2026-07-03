package Net::Blossom::BlobDescriptor;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();

use Carp qw(croak);
use Class::Tiny qw(url sha256 size type uploaded extra);

my $HEX64 = qr/\A[0-9a-f]{64}\z/;

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(url sha256 size type uploaded extra);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    for my $field (qw(url sha256 size type uploaded)) {
        croak "$field is required" unless defined $args{$field};
    }
    croak "url is required" unless length $args{url};
    croak "sha256 must be 64-char lowercase hex" unless $args{sha256} =~ $HEX64;
    croak "size must be a non-negative integer"
        unless $args{size} =~ /\A\d+\z/;
    croak "type is required" unless length $args{type};
    croak "uploaded must be a non-negative integer"
        unless $args{uploaded} =~ /\A\d+\z/;
    croak "extra must be a hash reference"
        if defined $args{extra} && ref($args{extra}) ne 'HASH';

    $args{extra} = {} unless defined $args{extra};
    return bless \%args, $class;
}

sub from_hash {
    my ($class, $hash) = @_;
    croak "from_hash requires a hash reference" unless ref($hash) eq 'HASH';

    my %args;
    @args{qw(url sha256 size type uploaded)} = @{$hash}{qw(url sha256 size type uploaded)};

    my %extra = %$hash;
    delete @extra{qw(url sha256 size type uploaded)};
    return $class->new(%args, extra => \%extra);
}

sub get {
    my ($self, $field) = @_;
    return $self->$field if defined $field && $field =~ /\A(?:url|sha256|size|type|uploaded)\z/;
    return $self->extra->{$field};
}

sub to_hash {
    my ($self) = @_;
    return {
        url      => $self->url,
        sha256   => $self->sha256,
        size     => $self->size + 0,
        type     => $self->type,
        uploaded => $self->uploaded + 0,
        %{$self->extra},
    };
}

1;
