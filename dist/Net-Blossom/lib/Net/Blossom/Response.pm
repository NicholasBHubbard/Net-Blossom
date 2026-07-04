package Net::Blossom::Response;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();

use Carp qw(croak);
use Class::Tiny qw(method url status reason headers content);

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(method url status reason headers content);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    $args{headers} = {} unless defined $args{headers};
    $args{content} = '' unless defined $args{content};
    _validate_required_scalar(\%args, $_) for qw(method url status reason);
    _validate_status($args{status});
    croak "headers must be a hash reference" unless ref($args{headers}) eq 'HASH';
    croak "content must be a scalar" if ref($args{content});
    return bless \%args, $class;
}

sub header {
    my ($self, $name) = @_;
    return undef unless defined $name;
    my $wanted = lc $name;
    for my $key (keys %{$self->headers}) {
        return $self->headers->{$key} if lc($key) eq $wanted;
    }
    return undef;
}

sub _validate_required_scalar {
    my ($args, $field) = @_;
    croak "$field is required" unless exists $args->{$field} && defined $args->{$field};
    croak "$field must be a scalar" if ref($args->{$field});
    croak "$field is required" if $field =~ /\A(?:method|url)\z/ && !length $args->{$field};
}

sub _validate_status {
    my ($status) = @_;
    croak "status must be an HTTP status code"
        unless $status =~ /\A[1-5][0-9][0-9]\z/;
}

1;
