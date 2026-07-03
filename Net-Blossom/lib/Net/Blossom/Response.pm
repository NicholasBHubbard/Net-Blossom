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

1;
