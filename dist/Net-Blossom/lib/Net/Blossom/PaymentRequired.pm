package Net::Blossom::PaymentRequired;

use strictures 2;

use parent 'Net::Blossom::Error';

use Net::Blossom::_ConstructorArgs ();

use Carp qw(croak);
use Class::Tiny qw(method url status reason x_reason headers body payment_challenges);

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(method url status reason x_reason headers body payment_challenges);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    $args{headers} = {} unless defined $args{headers};
    $args{body} = '' unless defined $args{body};
    $args{payment_challenges} = {} unless defined $args{payment_challenges};
    croak "payment_challenges must be a hash reference"
        unless ref($args{payment_challenges}) eq 'HASH';

    return bless \%args, $class;
}

sub payment_methods {
    my ($self) = @_;
    return sort keys %{$self->payment_challenges};
}

sub payment_challenge {
    my ($self, $method) = @_;
    return undef unless defined $method;
    $method =~ s/\AX-//i;
    return $self->payment_challenges->{lc $method};
}

1;
