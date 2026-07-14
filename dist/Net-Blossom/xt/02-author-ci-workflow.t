use strictures 2;

use FindBin;
use Test::More;

plan skip_all => 'AUTHOR_TESTING is not set'
    unless $ENV{AUTHOR_TESTING};

my $root = _repo_root();
ok(-d "$root/dist/Net-Blossom", 'Net-Blossom distribution lives under dist');
ok(-d "$root/dist/Net-Blossom-Server", 'Net-Blossom-Server distribution lives under dist');
ok(-d "$root/dist/Net-Blossom-Server-Backend-SQLite", 'Net-Blossom-Server-Backend-SQLite distribution lives under dist');
ok(-d "$root/dist/Net-Blossom-Server-Backend-Postgres", 'Net-Blossom-Server-Backend-Postgres distribution lives under dist');
ok(-d "$root/dist/Net-Blossom-Server-Backend-S3", 'Net-Blossom-Server-Backend-S3 distribution lives under dist');

my $workflow = "$root/.github/workflows/ci.yml";
ok(-f $workflow, 'GitHub Actions CI workflow exists');
done_testing and exit unless -f $workflow;

open my $fh, '<', $workflow
    or die "Unable to read $workflow: $!";
my $yaml = do { local $/; <$fh> };

my $kind_config = "$root/.github/rook/kind.yaml";
ok(-f $kind_config, 'Ceph CI KinD configuration exists');
my $kind = '';
if (-f $kind_config) {
    open my $kind_fh, '<', $kind_config
        or die "Unable to read $kind_config: $!";
    $kind = do { local $/; <$kind_fh> };
}

my $cluster_config = "$root/.github/rook/cluster.yaml";
ok(-f $cluster_config, 'Ceph cluster configuration exists');
my $cluster = '';
if (-f $cluster_config) {
    open my $cluster_fh, '<', $cluster_config
        or die "Unable to read $cluster_config: $!";
    $cluster = do { local $/; <$cluster_fh> };
}

my $storage_config = "$root/.github/rook/storage.yaml";
ok(-f $storage_config, 'Ceph local block storage configuration exists');
my $storage = '';
if (-f $storage_config) {
    open my $storage_fh, '<', $storage_config
        or die "Unable to read $storage_config: $!";
    $storage = do { local $/; <$storage_fh> };
}

my $object_config = "$root/.github/rook/object.yaml";
ok(-f $object_config, 'Ceph object-store configuration exists');
my $object = '';
if (-f $object_config) {
    open my $object_fh, '<', $object_config
        or die "Unable to read $object_config: $!";
    $object = do { local $/; <$object_fh> };
}

like($yaml, qr/perl-version:\s*\[\s*["']?5\.16["']?\s*,\s*["']?latest["']?\s*\]/,
    'CI tests Perl 5.16 and latest');
like($yaml, qr/actions\/checkout\@v7/,
    'CI uses current checkout action');
like($yaml, qr/shogo82148\/actions-setup-perl\@v1/,
    'CI sets up Perl with actions-setup-perl');
unlike($yaml, qr/(?:p5-CBOR-Free|reviewed CBOR::Free|\.deps\/p5-CBOR-Free)/,
    'CI installs the released CBOR::Free dependency');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/dist\/Net-Blossom(?:\s|$)/,
    'CI installs Net-Blossom dependencies into local');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/dist\/Net-Blossom-Server(?:\s|$)/,
    'CI installs Net-Blossom-Server dependencies into local');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\s+\.\/dist\/Net-Blossom-Server(?:\s|$)/,
    'CI installs Net-Blossom-Server into local');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/dist\/Net-Blossom-Server-Backend-SQLite(?:\s|$)/,
    'CI installs Net-Blossom-Server-Backend-SQLite dependencies into local');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/dist\/Net-Blossom-Server-Backend-Postgres(?:\s|$)/,
    'CI installs Net-Blossom-Server-Backend-Postgres dependencies into local');
like($yaml, qr/postgres:16/,
    'CI provisions Postgres for backend tests');
like($yaml, qr/NET_BLOSSOM_POSTGRES_DSN/,
    'CI configures Postgres backend test DSN');
like($yaml, qr/dxflrs\/garage:v2\.3\.0/,
    'CI provisions Garage for S3 compatibility tests');
is(() = $yaml =~ /--name\s+blossom-garage-[123]\b/g, 3,
    'CI provisions three named Garage nodes');
unlike($yaml, qr/garage[^\n]*--single-node/,
    'CI does not run Garage in single-node mode');
like($yaml, qr/NET_BLOSSOM_S3_ENDPOINT/,
    'CI configures live S3 compatibility tests');
like($yaml, qr/NET_BLOSSOM_S3_PEER_ENDPOINT:\s*"http:\/\/127\.0\.0\.1:3902"/,
    'CI gives the second backend node a separate S3 gateway');
like($yaml, qr/--publish\s+3902:3900/,
    'CI exposes a second Garage S3 gateway');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*--with-develop\b[^\n]*--installdeps\s+\.\/dist\/Net-Blossom-Server-Backend-S3(?:\s|$)/,
    'CI installs S3 backend dependencies into local');
like($yaml, qr/prove\s+dist\/Net-Blossom\/t\s+dist\/Net-Blossom\/t\/bud\s+dist\/Net-Blossom-Server\/t/,
    'CI runs regular tests');
like($yaml, qr/prove\s+dist\/Net-Blossom\/t\s+dist\/Net-Blossom\/t\/bud\s+dist\/Net-Blossom-Server\/t\s+dist\/Net-Blossom-Server-Backend-SQLite\/t/,
    'CI runs SQLite backend regular tests');
like($yaml, qr/prove\s+dist\/Net-Blossom\/t\s+dist\/Net-Blossom\/t\/bud\s+dist\/Net-Blossom-Server\/t\s+dist\/Net-Blossom-Server-Backend-SQLite\/t\s+dist\/Net-Blossom-Server-Backend-Postgres\/t/,
    'CI runs Postgres backend regular tests');
like($yaml, qr/dist\/Net-Blossom-Server-Backend-S3\/t/,
    'CI runs S3 backend regular tests');
like($yaml, qr/AUTHOR_TESTING=1\s+prove\s+dist\/Net-Blossom\/xt\s+dist\/Net-Blossom-Server\/xt\s+dist\/Net-Blossom-Server-Backend-SQLite\/xt\s+dist\/Net-Blossom-Server-Backend-Postgres\/xt/,
    'CI runs author tests');
like($yaml, qr/dist\/Net-Blossom-Server-Backend-S3\/xt/,
    'CI runs S3 backend author tests');
like($yaml, qr/if:\s+matrix\.perl-version\s+==\s+'latest'/,
    'CI gates coverage to latest Perl');
like($yaml, qr/cpanm\s+-llocal\b[^\n]*--notest\b[^\n]*Devel::Cover\b/,
    'CI installs Devel::Cover separately');
like($yaml, qr/COVERAGE_TESTING=1\s+AUTHOR_TESTING=1\s+prove\s+dist\/Net-Blossom\/xt\/06-author-coverage\.t\s+dist\/Net-Blossom-Server\/xt\/05-author-coverage\.t\s+dist\/Net-Blossom-Server-Backend-SQLite\/xt\/04-author-coverage\.t\s+dist\/Net-Blossom-Server-Backend-Postgres\/xt\/04-author-coverage\.t/,
    'CI runs opt-in coverage author tests');
like($yaml, qr/dist\/Net-Blossom-Server-Backend-S3\/xt\/04-author-coverage\.t/,
    'CI runs S3 backend coverage author test');
like($yaml, qr/^  ceph:\s*$/m,
    'CI has a dedicated mandatory Ceph job');
like($yaml, qr/^  pull_request:\s*\n\njobs:/m,
    'CI runs the mandatory jobs on every pull request');
unlike($yaml, qr/^  ceph:.*?^\s{4}(?:if|continue-on-error):/ms,
    'Ceph job is not conditional or allowed to fail');
like($yaml, qr/Free disk space.*?tool-cache:\s*false/s,
    'Ceph disk cleanup preserves the tool cache required by KinD');
like($yaml, qr/Free disk space.*?large-packages:\s*true.*?android:\s*true.*?dotnet:\s*true.*?haskell:\s*true/s,
    'Ceph disk cleanup frees space required by the monitor database');
like($yaml, qr/rook\/rook\/v1\.20\.2/,
    'CI pins Rook release manifests');
like($yaml, qr/kindest\/node:v1\.36\.1/,
    'CI pins the Ceph job Kubernetes node image');
like($yaml, qr/BLUESTORE_SLOW_OP_ALERT/,
    'Ceph gate permits the loop-device slow-operation warning');
like($yaml, qr/select\(\. != "BLUESTORE_SLOW_OP_ALERT"\)/,
    'Ceph gate rejects health warnings unrelated to loop-device performance');
like($yaml, qr/\.pgmap\.num_pgs\s*>\s*0/,
    'Ceph gate requires placement groups');
like($yaml, qr/all\(\.pgmap\.pgs_by_state\[\];\s*\.state_name\s*==\s*"active\+clean"\)/,
    'Ceph gate requires every placement group to be active and clean');
like($yaml, qr/kubectl create -f \.github\/rook\/storage\.yaml.*?kubectl create -f \.github\/rook\/cluster\.yaml/s,
    'CI creates local block volumes before the Ceph cluster');
like($yaml, qr/dist\/Net-Blossom-Server-Backend-S3\/t\/21-LiveMultiNode\.t/,
    'CI runs the live cross-node S3 backend test');
like($yaml, qr/port-forward\s+"pod\/\$\{rgw_pods\[0\]\}"\s+3900:8080/,
    'Ceph test forwards the first RGW pod');
like($yaml, qr/port-forward\s+"pod\/\$\{rgw_pods\[1\]\}"\s+3901:8080/,
    'Ceph test forwards a different RGW pod');

my @workers = $kind =~ /(^  - role: worker\n.*?)(?=^  - role:|\z)/msg;
is(scalar @workers, 3,
    'Ceph KinD cluster has three worker nodes');
unlike($kind, qr/^\s*-\s+hostPath:\s*\/dev\s*$/m,
    'Ceph workers do not share the host device directory');
for my $index (0 .. 2) {
    my $device = 100 + $index;
    like($workers[$index], qr/^\s*-\s+hostPath:\s*\/dev\/loop$device\s*$/m,
        "Ceph worker " . ($index + 1) . " receives only loop$device");
    is(() = $workers[$index] =~ /^\s*-\s+hostPath:\s*\/dev\/loop\d+\s*$/mg, 1,
        "Ceph worker " . ($index + 1) . ' receives one loop device');
}
like($cluster, qr/osd_memory_target:\s*["']?2147483648["']?/,
    'Ceph OSD memory target is valid and bounded for the CI runner');
like($cluster, qr/storageClassDeviceSets:.*?count:\s*3\b.*?portable:\s*false.*?storageClassName:\s*blossom-ceph-local.*?volumeMode:\s*Block/s,
    'Ceph uses three non-portable raw block PVCs');
unlike($cluster, qr/^\s+nodes:\s*\n.*?\/dev\/loop/ms,
    'Ceph does not discover loop devices through host LVM');
like($storage, qr/kubernetes\.io\/no-provisioner.*?volumeBindingMode:\s*WaitForFirstConsumer/s,
    'Ceph local storage class waits for node-aware scheduling');
is(() = $storage =~ /^kind:\s*PersistentVolume\s*$/mg, 3,
    'Ceph defines three static local block volumes');
for my $index (0 .. 2) {
    my $device = 100 + $index;
    my $node = $index ? "blossom-ceph-worker" . ($index + 1) : 'blossom-ceph-worker';
    like($storage, qr/local:\s*\n\s+path:\s*\/dev\/loop$device\b.*?values:\s*\n\s+-\s*$node\b/s,
        "Ceph loop$device volume is pinned to $node");
}
like($object, qr/metadataPool:.*?replicated:\s*\n\s+size:\s*3\b/s,
    'Ceph object metadata is replicated across three nodes');
like($object, qr/dataPool:.*?replicated:\s*\n\s+size:\s*3\b/s,
    'Ceph object data is replicated across three nodes');
like($object, qr/gateway:.*?instances:\s*3\b/s,
    'Ceph runs three object gateways');

done_testing;

sub _repo_root {
    my $dir = $FindBin::Bin;
    while (1) {
        return $dir if -d "$dir/.git";

        my $parent = "$dir/..";
        last if $parent eq $dir;
        $dir = $parent;
    }

    die "Unable to find repository root from $FindBin::Bin";
}
