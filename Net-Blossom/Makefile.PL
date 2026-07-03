use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Net::Blossom',
    VERSION_FROM     => 'lib/Net/Blossom.pm',
    ABSTRACT         => 'Perl client and protocol support for Blossom',
    AUTHOR           => 'Net::Blossom contributors',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.020',
    PREREQ_PM        => {},
    TEST_REQUIRES    => {
        'Test::More' => '0.98',
    },
);
