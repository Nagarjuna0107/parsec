# parsec

**Context savings for coding agents.** parsec is a local proxy and plugin for
Claude Code, OpenCode, Codex CLI, and Claude Desktop that cuts the tokens your
agent spends per turn: it blocks wasteful re-reads, breaks command loops, and
(with scoring enabled) curates the conversation context before each request,
cache-safely. Savings are measured per request against the provider's own
token counter, never estimated.

Everything runs on your machine with your own credentials. Model traffic never
touches anyone else's infrastructure.

## Install

One line, then sign in when the installer opens the browser:

```sh
curl -fsSL https://raw.githubusercontent.com/daseinlabs/plugins/main/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/daseinlabs/plugins/main/install.ps1 | iex
```

Or, with the Claude Code CLI:

```sh
claude plugin marketplace add https://github.com/daseinlabs/plugins
claude plugin install parsec@parsec-marketplace
```

Native `.pkg` and `.exe` installers for each release are on the
[releases page](https://github.com/daseinlabs/plugins/releases).

Then in a session: `/parsec:setup` routes your agent through the proxy,
`/parsec:savings` shows what it saved, `/parsec:share --preview` shows exactly
what opt-in telemetry would upload before anything leaves.

## What parsec sends

parsec is a proxy, so this section is the contract. Everything below can be
verified in `packages/proxy/src` and the schemas in `packages/contracts`.

| When | What leaves your machine | Where | Off switch |
|---|---|---|---|
| Always | Your model requests, with your own auth headers | The provider you already use (`api.anthropic.com` by default) | n/a — this is your agent's own traffic |
| Always, no key needed | An anonymous **install ping**: random install id, parsec version, OS, arch, list of configured harnesses. Sent at setup, on key changes, and every 6 hours while the proxy runs. Never your API key. | parsec platform | `PARSEC_INSTALL_REPORT=0` or `DO_NOT_TRACK=1` |
| With scoring enabled | **Chunk text** (each chunk capped at 2000 chars) plus structural features, for keep/cut scoring. The response is scores; the service does not learn what was dropped. | parsec scoring API | `PARSEC_FREEZE=off`, or run with no scoring endpoint |
| With a parsec key | **Savings-ledger rows**: token counts per request, model, harness, conversation and request ids. No prompt text. | parsec platform | remove the key (`/parsec:key`) or unset `PARSEC_PLATFORM_URL` |
| Opt-in only | Featurized trace sharing (`/parsec:share`) | parsec platform | Off by default; `--preview` shows the exact bytes first |

`~/.parsec/` holds local state: the savings ledger, score memo (hashes and
quantized scores only), and recordings if you enable `PARSEC_RECORD_DIR`.
Delete it whenever you like.

## Layout

| Package | Language | What |
|---|---|---|
| `packages/engine` | Rust | Chunking, featurization, deterministic freezing, readout. Pure library. |
| `packages/proxy` | Rust | The `parsec` binary: local proxy, hooks, MCP server, status line, harness setup. |
| `packages/mapgen` | Rust | Deterministic repo maps, outlines, symbol lookup for the explore agent. |
| `packages/contracts` | JSON Schema | Cross-language schemas: scoring API, savings ledger, telemetry, install report. |
| `packages/plugin` | Markdown/JSON | The Claude Code plugin (agents, skills, hooks, launcher shims). |
| `packages/opencode-plugin` | JS | OpenCode plugin shim. |
| `packages/installer` | Shell/Inno | Native macOS and Windows installer sources. |
| `packages/marketplace` | JSON | The marketplace manifest published to `daseinlabs/plugins`. |
| `packages/brain` | Python | The scoring service: GNN inference over a curator checkpoint, self-validating bundle, calibrated tau. Self-hostable. |

The training pipeline and the account platform are separate, closed
components. Everything here talks to them only over the contracts in
`packages/contracts`, and runs without them.

## Self-host the scoring service

The proxy runs without any scoring service (no-reread hook, loop breaker,
savings ledger). Curation needs one, and you can run it yourself: it is
`packages/brain`, one Python process holding the curator checkpoint and the
bge-large encoder.

```sh
# 1. a curator checkpoint — the released base model on the Hugging Face Hub
export PARSEC_CKPT=hf://<org>/<repo>/<checkpoint>.pt   # or a local path
# 2. the service (in-process bge-large; CPU works, a GPU is faster)
docker compose up -d                                   # http://127.0.0.1:8090
# 3. point the proxy at it
export PARSEC_BRAIN_URL=http://127.0.0.1:8090
```

`packages/brain/README.md` has the bare-uvicorn form, the auth options, and
a Cloud Run recipe. A self-hosted brain is where the chunk text in "What
parsec sends" goes; with your own host, nothing leaves your infrastructure.

## Build

```sh
cargo build --release   # engine, proxy (the `parsec` binary), mapgen
make check              # fmt + clippy + tests, same flags CI runs
make plugin             # build and install a local plugin binary for `claude --plugin-dir`
```

Rust 1.98 is pinned in `rust-toolchain.toml`. No model download, no network
needed for the Rust test suite. The scoring service's tests
(`make brain-test`) run their hermetic subset without a checkpoint. See
`CONTRIBUTING.md` for the dev loop.

## Invariants

These are what the test suite protects; see `DIRECTION.md §8`.

1. **Cache stability**: replayed conversations are byte-identical on every
   previously served turn.
2. **Parity**: the Rust port matches the reference implementation
   byte-for-byte on freezing and vector-for-vector on featurization.
3. **Fail open, but measured**: every layer degrades to passthrough, and
   fail-open events are counted.
4. **Measurement honesty**: savings only from the `count_tokens`
   counterfactual, never a modeled baseline.

## License

MIT, see `LICENSE`. Third-party notices and trademark note in
`THIRD_PARTY.md`. Security reports: `SECURITY.md`.
