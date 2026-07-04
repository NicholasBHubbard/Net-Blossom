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
    _validate_required_scalar(\%args, $_) for qw(method url status reason);
    _validate_status($args{status});
    croak "headers must be a hash reference" unless ref($args{headers}) eq 'HASH';
    croak "body must be a scalar" if ref($args{body});
    croak "x_reason must be a scalar" if defined $args{x_reason} && ref($args{x_reason});
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
