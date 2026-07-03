package Net::Blossom;

use strictures 2;

use Net::Blossom::Client;
use Net::Blossom::ServerList;
use Net::Blossom::URI;

our $VERSION = '0.001';

sub client {
    my $class = shift;
    return Net::Blossom::Client->new(@_);
}

1;
