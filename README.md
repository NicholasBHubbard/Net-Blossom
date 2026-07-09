# Net::Blossom

Perl implementation of the Blossom protocol:
<https://github.com/hzrd149/blossom>.

This repo contains two CPAN distributions:

- `dist/Net-Blossom`: shared protocol objects and the client library.
- `dist/Net-Blossom-Server`: server-side support and storage backend contracts.

`Net::Blossom::Server` currently supports `PUT /upload`, `HEAD /upload`,
`GET /<sha256>`, `HEAD /<sha256>`, `DELETE /<sha256>`,
`GET /list/<pubkey>`, `PUT /media`, `HEAD /media`, and `PUT /mirror`.
It also includes an allowlist-only HTTP mirror fetcher.

Run tests from the repository root:

```sh
plx prove dist/Net-Blossom/t dist/Net-Blossom/t/bud dist/Net-Blossom-Server/t
plx AUTHOR_TESTING=1 prove dist/Net-Blossom/xt dist/Net-Blossom-Server/xt
```

License: GNU General Public License version 3.
