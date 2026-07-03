# AGENTS.md

This repository is the Perl implementation of the Blossom protocol.

The project goal is to conform to the Blossom standard, keep the implementation boring and maintainable, and back behavior with strong tests and clear documentation.

The repository is licensed under the GNU General Public License version 3.

This is a monorepo with two CPAN distributions:

- `Net-Blossom` provides shared protocol components and the client library.
- `Net-Blossom-Server` provides server-side protocol support and depends on `Net::Blossom`.

Each distribution keeps regular tests in `t/` and author-only tests in `xt/`.

The upstream Blossom protocol repository can be cloned into `./blossom/`. That directory is gitignored and is useful when developing against the protocol specification.
