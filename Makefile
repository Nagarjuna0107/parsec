.PHONY: help fmt clippy rust-test check plugin lint-py release

help:
	@echo "make check    — rust fmt + clippy + tests (same flags CI runs)"
	@echo "make lint-py  — ruff check + format check on the Python helpers"
	@echo "make plugin   — build + install the local (gitignored) plugin binary"
	@echo "make release VERSION=X.Y.Z — bump workspace version, commit, tag (push = publish)"

# Rust static checks + tests. CI (.github/workflows/ci.yml) and pre-commit
# call these targets so the flags can't drift.
fmt:
	cargo fmt --all --check

clippy:
	cargo clippy --workspace --all-targets --no-deps -- -D warnings

rust-test:
	cargo test --workspace --quiet

check: fmt clippy rust-test

# Python helpers (parity generators, mock upstream, mitmproxy addon).
lint-py:
	ruff check .
	ruff format --check .

# Build + install the local (gitignored) plugin binary. BRAIN_URL bakes the
# default scoring endpoint (brain.rs BAKED_BRAIN_URL); PLATFORM_URL bakes the
# savings-ledger sink (ledger_ship.rs BAKED_PLATFORM_URL). release.yml stamps
# the same two knobs from repository variables. Omit both for a dev build
# that reads PARSEC_BRAIN_URL / PARSEC_PLATFORM_URL at runtime, or runs with
# no scoring service at all (the no-reread hook and passthrough still work).
#   make plugin
#   make plugin BRAIN_URL=https://brain.example.com PLATFORM_URL=https://platform.example.com
plugin:
	PARSEC_DEFAULT_BRAIN_URL="$(BRAIN_URL)" PARSEC_DEFAULT_PLATFORM_URL="$(PLATFORM_URL)" scripts/refresh_plugin_bin.sh

release:
	scripts/release.sh $(VERSION)
