# Net::Blossom

This repository contains the Perl implementation of the Blossom protocol.

Blossom is a protocol for storing and retrieving blobs addressed by sha256 hash
on public media servers. The upstream protocol lives at
<https://github.com/hzrd149/blossom>.

## Repository layout

This is a monorepo with separate CPAN distributions:

- `Net-Blossom` contains protocol primitives and the client library.
- `Net-Blossom-Server` contains server-side protocol machinery and depends on
  `Net::Blossom`.

Keeping these separate matters. Client users should not inherit server, storage,
daemon, or web framework dependencies. Server deployments need extension points
for storage, authorization, rate limits, observability, and operational policy.

## Status

This repository is in initial setup. The modules load, but protocol behavior is
not implemented yet.

## Development environment

The repo uses `plx` with project-local `local::lib` roots:

- `local` for project dependencies
- `devel` for developer tools

On this checkout, `plx` is available at:

```sh
/home/_73/.local/bin/plx
```

Install distribution dependencies into `local`:

```sh
mkdir -p .cpanm/work
/home/_73/.local/bin/plx PERL_CPANM_HOME="$PWD/.cpanm" cpanm -llocal --installdeps ./Net-Blossom
/home/_73/.local/bin/plx PERL_CPANM_HOME="$PWD/.cpanm" cpanm -llocal --installdeps ./Net-Blossom-Server
```

Run tests from the repository root:

```sh
/home/_73/.local/bin/plx prove Net-Blossom/t Net-Blossom-Server/t
```

Inspect the active Perl layout:

```sh
/home/_73/.local/bin/plx --config
/home/_73/.local/bin/plx --libs
```
