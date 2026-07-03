use strictures 2;

use FindBin;
use Module::CoreList ();
use Test::More;

plan skip_all => 'AUTHOR_TESTING is not set'
    unless $ENV{AUTHOR_TESTING};

my $minimum_perl = '5.016';
my $root = "$FindBin::Bin/../..";

for my $file (
    "$root/Net-Blossom/Makefile.PL",
    "$root/Net-Blossom/cpanfile",
    "$root/Net-Blossom-Server/Makefile.PL",
    "$root/Net-Blossom-Server/cpanfile",
) {
    for my $module (_dependency_modules($file)) {
        next if $module eq 'perl';

        ok(
            !exists $Module::CoreList::version{$minimum_perl}{$module},
            "$file dependency $module is not core in Perl $minimum_perl",
        );
    }
}

done_testing;

sub _dependency_modules {
    my ($file) = @_;

    open my $fh, '<', $file
        or die "Unable to read $file: $!";

    my @modules;
    my $makefile_prereq;

    while (my $line = <$fh>) {
        if ($line =~ /^\s*(CONFIGURE_REQUIRES|PREREQ_PM|TEST_REQUIRES|BUILD_REQUIRES)\s*=>\s*\{\s*$/) {
            $makefile_prereq = 1;
            next;
        }

        if ($makefile_prereq) {
            if ($line =~ /^\s*\},?\s*$/) {
                $makefile_prereq = 0;
                next;
            }

            push @modules, $1
                if $line =~ /^\s*'([^']+)'\s*=>/;

            next;
        }

        push @modules, $1
            if $line =~ /^\s*requires\s+'([^']+)'/;
    }

    return @modules;
}
