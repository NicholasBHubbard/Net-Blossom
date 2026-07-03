use strictures 2;

use FindBin;
use Test::More;

plan skip_all => 'AUTHOR_TESTING is not set'
    unless $ENV{AUTHOR_TESTING};

eval 'use Test::Pod 1.52; 1'
    or plan skip_all => 'Test::Pod 1.52 is required for author tests';

all_pod_files_ok("$FindBin::Bin/../lib");
