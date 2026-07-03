package Net::Blossom;

use strictures 2;

use Net::Blossom::Client;

our $VERSION = '0.001';

sub client {
    my $class = shift;
    return Net::Blossom::Client->new(@_);
}

1;
