# AGENTS.md

This repository is the Perl implementation of [the Blossom protocol](https://github.com/hzrd149/blossom).

The project goal is to conform to the Blossom standard, keep the implementation boring and maintainable, and back behavior with strong tests and clear documentation.

This is a monorepo with multiple CPAN distributions under `./dist/`.

Each distribution keeps regular tests in `t/` and author-only tests in `xt/`.

The upstream Blossom protocol repository can be cloned into `./blossom/`. That directory is gitignored and is useful when developing against the protocol specification.
