# Contributing to Open Memex

Thanks for taking an interest. Open Memex is a macOS app (Flutter) on a Rust core.

## Build from source

You need a recent Rust toolchain and Flutter with macOS desktop support.

```sh
cargo build
cd app && flutter run -d macos
```

## Run the tests

```sh
cargo test --workspace
cd app && flutter test
```

The release-script tests need `git-filter-repo`:

```sh
brew install git-filter-repo
```

## Before you open a PR

Open an issue before a large PR, so we can agree on the approach before you
spend the time. Small fixes (a typo, a clear bug with a test) can go straight
to a PR.

Keep a PR to one change, and include tests for new behaviour.

## Licence

Open Memex is MIT licensed. Contributions are accepted under the same terms:
MIT inbound = outbound, no CLA. You keep your copyright and there is nothing
to sign.

## How outside PRs are reviewed

The maintainer reads every outside PR before running anything from it. That
includes tests, build scripts and CI changes. Expect a read-through first, so a
review can take a little while.

## Security

Report vulnerabilities privately. See [SECURITY.md](SECURITY.md).
