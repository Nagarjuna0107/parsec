# Contributing to parsec

Thanks for looking. This document covers the dev loop, what CI checks, the
things that are deliberately frozen, and how releases work.

## Dev loop

```sh
git clone https://github.com/daseinlabs/parsec
cd parsec
make check          # cargo fmt --check, clippy -D warnings, cargo test
make lint-py        # ruff on the Python helpers (pip install ruff)
scripts/install_githooks.sh   # optional: pre-commit fmt + clippy
```

The toolchain is pinned in `rust-toolchain.toml`; rustup picks it up
automatically. The test suite needs no network, no model, and no account.

To try a change in a real session:

```sh
make plugin                         # builds and installs the local plugin binary
claude --plugin-dir packages/plugin
```

To run the proxy by hand against a fake upstream:

```sh
python3 scripts/mock_upstream.py &          # Anthropic-shaped stub on :8091
PARSEC_UPSTREAM=http://127.0.0.1:8091 scripts/proxy_dev.sh
```

Without `PARSEC_BRAIN_URL` the proxy runs passthrough curation: the
no-reread hook, governor, tool prune, and savings ledger all work; nothing is
scored. That is the configuration CI and most contributors run in.

## What CI checks

Every PR runs, on Linux:

- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets --no-deps -- -D warnings`
- `cargo test --workspace`
- parity fixture directories are non-empty (an emptied fixture dir must fail
  loudly, not pass vacuously)
- `cargo deny check` (licenses, advisories, sources — policy in `deny.toml`)
- `ruff check` and `ruff format --check` on the Python helpers
- contract examples validate against their JSON Schemas

And a release-shaped build of the `parsec` binary on macOS and Windows, so a
platform-specific compile break surfaces on the PR rather than on a tag.

## Things that are frozen

**Parity fixtures** (`packages/engine/parity/fixtures`,
`packages/proxy/parity/fixtures`) are golden outputs generated from a Python
reference implementation that lives outside this repository. They are the
port's definition of done. Do not regenerate or hand-edit them. If your change
legitimately alters freezing or featurization output, say so in the PR and a
maintainer will regenerate the fixtures against the reference. The generator
scripts (`gen_*.py`) are kept in-tree for provenance; they read the reference
checkout from `ACC_ROOT` (default: a sibling directory next to this repo).

**Served bytes are deterministic.** No wall clock, RNG, HashMap iteration
order, or process-local state may influence what the proxy sends upstream.
`serde_json` keeps `preserve_order`. If you are unsure whether something is on
the serving path, ask in the PR.

**Fail open.** Nothing on the request path may panic. Errors degrade to
passthrough and increment a counter. Clippy will not catch an `expect` in the
wrong place; reviewers will.

## Style

- Rust: `cargo fmt` defaults, clippy clean at `-D warnings`. Crate-level
  `//!` docs explain what the crate is for; module docs explain invariants.
  Comments say *why*, and cite `DIRECTION.md §n` when a design rule applies.
- Python helpers: `ruff` per `ruff.toml`. Standard library only unless the
  file header says otherwise.
- No TypeScript in client or plugin code (`DIRECTION.md §7b`).
- Every new environment variable is documented in
  `docs/environment-variables.md` in the same PR.

## Commits and sign-off

We use the [Developer Certificate of Origin](https://developercertificate.org/).
Sign your commits with `git commit -s`; that adds a `Signed-off-by` line
certifying you have the right to submit the work under the MIT license. No
CLA.

Commit subjects: imperative, under 72 characters, scoped when it helps
(`proxy: ...`, `engine: ...`, `installer: ...`).

## Releases

Releases are tag-driven and produced by `.github/workflows/release.yml`:

1. `make release VERSION=X.Y.Z` bumps the workspace version, commits, and tags.
2. Pushing the tag builds `parsec` for macOS arm64, Linux x64, and Windows
   x64, assembles the plugin zip and the native installers, and attaches them
   to a GitHub Release on this repository.
3. The same run publishes the assembled plugin, binaries, and install scripts
   to the public distribution repository `daseinlabs/plugins`, which is what
   the marketplace and the one-line installers read. That step needs a
   publish token and is skipped on forks.

Signing (Apple Developer ID, notarization, Azure Artifact Signing for
Windows) switches on when the corresponding secrets are present and builds
unsigned otherwise, so forks and PRs still get a working matrix.

The two compile-time knobs `PARSEC_DEFAULT_BRAIN_URL` and
`PARSEC_DEFAULT_PLATFORM_URL` are baked from repository variables so released
binaries reach the hosted services with zero configuration. A build without
them reads `PARSEC_BRAIN_URL` / `PARSEC_PLATFORM_URL` at runtime, or runs with
neither.

See `docs/release-channels.md` for the channel policy.

## Reporting security issues

See `SECURITY.md`. Please do not file vulnerabilities as public issues.
