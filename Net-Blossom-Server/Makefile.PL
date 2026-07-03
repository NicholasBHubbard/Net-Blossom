use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Net::Blossom::Server',
    VERSION_FROM     => 'lib/Net/Blossom/Server.pm',
    ABSTRACT         => 'Server support for the Blossom protocol',
    AUTHOR           => 'Net::Blossom contributors',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.020',
    PREREQ_PM        => {
        'Net::Blossom' => '0.001',
    },
    TEST_REQUIRES    => {
        'Test::More' => '0.98',
    },
);
