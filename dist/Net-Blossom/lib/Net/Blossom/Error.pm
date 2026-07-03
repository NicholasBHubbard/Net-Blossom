package Net::Blossom::Error;

use strictures 2;

use Net::Blossom::_ConstructorArgs ();

use Carp qw(croak);
use Class::Tiny qw(method url status reason x_reason headers body);
use overload '""' => 'as_string', fallback => 1;

sub new {
    my $class = shift;
    my %args = Net::Blossom::_ConstructorArgs::normalize(@_);
    my %known = map { $_ => 1 } qw(method url status reason x_reason headers body);
    my @unknown = grep { !exists $known{$_} } keys %args;
    croak "unknown argument(s): " . join(', ', sort @unknown) if @unknown;

    $args{headers} = {} unless defined $args{headers};
    $args{body} = '' unless defined $args{body};
    return bless \%args, $class;
}

sub as_string {
    my ($self) = @_;
    my $message = $self->status . ' ' . ($self->reason || 'HTTP error');
    $message .= ': ' . $self->x_reason if defined $self->x_reason && length $self->x_reason;
    $message .= ' at ' . $self->method . ' ' . $self->url
        if defined $self->method && defined $self->url;
    return $message;
}

1;
