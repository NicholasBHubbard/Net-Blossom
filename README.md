# Net::Blossom

This repository contains the Perl implementation of the Blossom protocol.

Blossom is a protocol for storing and retrieving blobs addressed by sha256 hash
on public media servers. The upstream protocol lives at
<https://github.com/hzrd149/blossom>.

## Repository layout

This is a monorepo with separate CPAN distributions:

- `dist/Net-Blossom` contains protocol primitives and the client library.
- `dist/Net-Blossom-Server` contains server-side protocol machinery and depends on
  `Net::Blossom`.

Keeping these separate matters. Client users should not inherit server, storage,
daemon, or web framework dependencies. Server deployments need extension points
for storage, authorization, rate limits, observability, and operational policy.

## Status

This repository is in early implementation. `Net-Blossom` currently provides
blob descriptors, response and error objects, a small HTTP client, and BUD-11
authorization token creation, BUD-10 Blossom URI parsing/building, and BUD-03
user server list handling, BUD-04 mirror requests, BUD-05 media processing
client requests, BUD-06 upload preflight requests, and BUD-08 NIP-94 metadata
tags. Server behavior is still scaffold-only.

## License

This repository is licensed under the GNU General Public License version 3. See
`LICENSE`.

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
/home/_73/.local/bin/plx PERL_CPANM_HOME="$PWD/.cpanm" cpanm -llocal --installdeps ./dist/Net-Blossom
/home/_73/.local/bin/plx PERL_CPANM_HOME="$PWD/.cpanm" cpanm -llocal --installdeps ./dist/Net-Blossom-Server
```

Run tests from the repository root:

```sh
/home/_73/.local/bin/plx prove dist/Net-Blossom/t dist/Net-Blossom/t/bud dist/Net-Blossom-Server/t
```

Run author tests from the repository root:

```sh
/home/_73/.local/bin/plx AUTHOR_TESTING=1 prove dist/Net-Blossom/xt dist/Net-Blossom-Server/xt
```

Inspect the active Perl layout:

```sh
/home/_73/.local/bin/plx --config
/home/_73/.local/bin/plx --libs
```
