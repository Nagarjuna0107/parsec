.PHONY: help fmt clippy rust-test check plugin lint-py brain-test brain-up brain-down release

help:
	@echo "make check    — rust fmt + clippy + tests (same flags CI runs)"
	@echo "make lint-py  — ruff check + format check on the Python helpers"
	@echo "make brain-test — scoring-service unit tests (hermetic ones run without a checkpoint)"
	@echo "make brain-up / brain-down — self-host the scoring service with docker compose"
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

# Python helpers (parity generators, mock upstream, mitmproxy addon) and the
# scoring service. packages/brain is lint-only (ruff.toml [format] excludes it).
lint-py:
	ruff check .
	ruff format --check .

# Scoring service (packages/brain). Tests that need a curator checkpoint skip
# loudly unless PARSEC_CKPT points at one; the hermetic set always runs.
#   python -m venv packages/brain/.venv && packages/brain/.venv/bin/pip install -e "packages/brain[test]"
brain-test:
	cd packages/brain && python -m pytest tests/ -q

brain-up:
	docker compose up -d --build brain

brain-down:
	docker compose down

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
