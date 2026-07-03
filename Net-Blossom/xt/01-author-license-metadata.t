use strictures 2;

use FindBin;
use Test::More;

plan skip_all => 'AUTHOR_TESTING is not set'
    unless $ENV{AUTHOR_TESTING};

open my $fh, '<', "$FindBin::Bin/../Makefile.PL"
    or die "Unable to read Makefile.PL: $!";
my $makefile = do { local $/; <$fh> };

like(
    $makefile,
    qr/LICENSE\s*=>\s*'gpl_3'/,
    'Makefile.PL declares GPL-3 license metadata',
);

done_testing;
