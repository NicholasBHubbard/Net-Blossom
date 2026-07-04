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
authorization token creation, BUD-10 Blossom URI parsing/building, BUD-03 user
server list handling, BUD-04 mirror requests, BUD-05 media processing client
requests, BUD-06 upload preflight requests, BUD-07 payment challenge handling,
BUD-08 NIP-94 metadata tags, BUD-09 blob report requests, and BUD-12 client list
and delete requests.

`Net-Blossom-Server` currently provides framework-neutral request and response
objects, a storage contract, server-owned upload hashing, and handlers for
`PUT /upload`, `GET /<sha256>`, `DELETE /<sha256>`, and
`GET /list/<pubkey>`.

## API contracts

`Net::Blossom::Client->list_blobs`, `Net::Blossom::ServerList->servers`, and
`Net::Blossom::ServerList->blob_urls_for` return array references.

`Net::Blossom::Client` accepts `auth` as a static `Authorization` header string,
a code reference, or an object with `authorization_header(%context)`. Code
references and objects receive `method`, `url`, `action`, and `sha256` context.
`Net::Blossom::AuthToken` objects can be passed directly when a prebuilt BUD-11
token is appropriate.

HTTP result objects require `method`, `url`, `status`, and `reason` at
construction time. `Net::Blossom::PaymentRequired` is a `Net::Blossom::Error`
with payment challenge accessors.

## Payment handling

BUD-07 `402 Payment Required` responses croak as
`Net::Blossom::PaymentRequired`, which is also a `Net::Blossom::Error`. The
error exposes payment challenges with `payment_methods` and
`payment_challenge($method)`.

Client calls that may be retried with proof accept a `payment` hash reference
whose keys are payment methods such as `cashu`, `lightning`, or future `X-*`
method names. The client sends those proofs as `X-Cashu`, `X-Lightning`, or the
matching future `X-*` header. `HEAD` requests reject payment proof headers; use
the preflight challenge to complete payment and then retry the corresponding
`GET` or `PUT`.

`Net::Blossom` does not complete Cashu or Lightning payments itself. Application
code can use `Net::Nostr::Core` or another wallet/payment service to satisfy the
challenge and then pass the proof back to the Blossom client.

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
