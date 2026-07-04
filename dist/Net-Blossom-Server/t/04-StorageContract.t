use strictures 2;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;

use Net::Blossom::Server::Test::StorageContract qw(storage_contract_ok);

{
    package Local::ContractStorage;
    use strictures 2;

    use Net::Blossom::BlobDescriptor;
    use Net::Blossom::Server::BlobResult;

    sub new {
        my ($class) = @_;
        return bless {
            blobs  => {},
            owners => {},
        }, $class;
    }

    sub begin_upload {
        my ($self, %context) = @_;
        return Local::ContractUpload->new($self, \%context);
    }

    sub get_blob {
        my ($self, $sha256) = @_;
        my $entry = $self->{blobs}{$sha256};
        return unless defined $entry;
        return Net::Blossom::Server::BlobResult->new(
            descriptor => $entry->{descriptor},
            body       => $entry->{body},
        );
    }

    sub delete_blob {
        my ($self, $sha256, %opts) = @_;
        return 0 unless exists $self->{blobs}{$sha256};

        if (defined $opts{pubkey}) {
            return 0 unless exists $self->{owners}{$opts{pubkey}}
                && $self->{owners}{$opts{pubkey}}{$sha256};
            delete $self->{owners}{$opts{pubkey}}{$sha256};
        }
        else {
            for my $pubkey (keys %{$self->{owners}}) {
                delete $self->{owners}{$pubkey}{$sha256};
            }
        }

        my $owned = 0;
        for my $pubkey (keys %{$self->{owners}}) {
            $owned ||= exists $self->{owners}{$pubkey}{$sha256};
        }
        delete $self->{blobs}{$sha256} unless $owned;

        return 1;
    }

    sub list_blobs {
        my ($self, $pubkey, %opts) = @_;
        my @sha256 = keys %{$self->{owners}{$pubkey} || {}};
        my @blobs = sort {
            $b->uploaded <=> $a->uploaded || $a->sha256 cmp $b->sha256
        } grep { defined } map { $self->{blobs}{$_}{descriptor} } @sha256;

        if (defined $opts{cursor}) {
            while (@blobs && $blobs[0]->sha256 ne $opts{cursor}) {
                shift @blobs;
            }
            shift @blobs if @blobs;
        }

        splice @blobs, $opts{limit} if defined $opts{limit} && @blobs > $opts{limit};
        return \@blobs;
    }
}

{
    package Local::ContractUpload;
    use strictures 2;

    use Net::Blossom::BlobDescriptor;

    sub new {
        my ($class, $storage, $context) = @_;
        return bless {
            storage => $storage,
            context => $context,
            chunks  => [],
            aborted => 0,
        }, $class;
    }

    sub write {
        my ($self, $chunk) = @_;
        push @{$self->{chunks}}, $chunk;
        return length $chunk;
    }

    sub commit {
        my ($self, %metadata) = @_;
        my $body = join '', @{$self->{chunks}};
        my $created = exists $self->{storage}{blobs}{$metadata{sha256}} ? 0 : 1;
        my $descriptor = Net::Blossom::BlobDescriptor->new(
            url      => "https://cdn.example.com/$metadata{sha256}.bin",
            sha256   => $metadata{sha256},
            size     => $metadata{size},
            type     => $metadata{type},
            uploaded => $metadata{uploaded},
        );

        $self->{storage}{blobs}{$metadata{sha256}} = {
            descriptor => $descriptor,
            body       => $body,
        };
        $self->{storage}{owners}{$metadata{pubkey}}{$metadata{sha256}} = 1
            if defined $metadata{pubkey};

        return {
            descriptor => $descriptor,
            created    => $created,
        };
    }

    sub abort {
        my ($self) = @_;
        $self->{aborted}++;
        return 1;
    }
}

storage_contract_ok(
    name    => 'in-memory contract storage',
    storage => sub { Local::ContractStorage->new },
);

done_testing;
