use strictures 2;

use FindBin;
use Test::More;

plan skip_all => 'AUTHOR_TESTING is not set'
    unless $ENV{AUTHOR_TESTING};

my $workflow = "$FindBin::Bin/../../.github/workflows/ci.yml";
ok(-f $workflow, 'GitHub Actions CI workflow exists');
done_testing and exit unless -f $workflow;

open my $fh, '<', $workflow
    or die "Unable to read $workflow: $!";
my $yaml = do { local $/; <$fh> };

like($yaml, qr/perl-version:\s*\[\s*["']?5\.16["']?\s*,\s*["']?latest["']?\s*\]/,
    'CI tests Perl 5.16 and latest');
like($yaml, qr/shogo82148\/actions-setup-perl\@v1/,
    'CI sets up Perl with actions-setup-perl');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/Net-Blossom/,
    'CI installs Net-Blossom dependencies into local');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/Net-Blossom-Server/,
    'CI installs Net-Blossom-Server dependencies into local');
like($yaml, qr/prove\s+Net-Blossom\/t\s+Net-Blossom\/t\/bud\s+Net-Blossom-Server\/t/,
    'CI runs regular tests');
like($yaml, qr/AUTHOR_TESTING=1\s+prove\s+Net-Blossom\/xt\s+Net-Blossom-Server\/xt/,
    'CI runs author tests');

done_testing;
