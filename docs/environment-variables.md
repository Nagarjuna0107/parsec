# Environment variables

Every env var read anywhere in this repo, grouped by the process that reads
it. Source of truth is the read site (file:line drifts; the var names and
defaults below are asserted by tests where noted). Conventions:

- `PARSEC_*` — ours. Client proxy vars are set in the plugin/hook
  environment; brain vars are set on the Cloud Run service.
- `AC_*` — inherited from the `adaptive-context-clean` reference. On the
  brain these are **parity pins** (see §7): almost never set by hand.
- Unset ⇒ the listed default. "on/off" vars follow the repo idiom: any value
  except the literal `off` (or `0` where noted) means on.

## 1. Client proxy — runtime (`parsec` binary)

Read in `packages/proxy/src/server.rs`, `main.rs`, `hook.rs`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_PROXY_PORT` | `8082` | Port the proxy binds on 127.0.0.1. |
| `PARSEC_UPSTREAM` | `https://api.anthropic.com` | Upstream base URL (bench points this at the mock upstream / usage gateway). |
| `ANTHROPIC_BASE_URL` | unset | Read by the hook to find the proxy the plugin routed Claude Code at; autostart only engages when it is set. |
| `PARSEC_PROXY_AUTOSTART` | on | `0` disables the hook's proxy autostart. |
| `PARSEC_PROXY_IDLE_EXIT_S` | `0` (never) | Idle seconds before the proxy exits; the hook sets a default when it autostarts and the var is unset. |
| `PARSEC_SESSION_TTL_S` | `3600` | Per-conversation state TTL. |
| `PARSEC_SESSION_MAX` | `512` | Conversation-state cap (LRU beyond this). |
| `PARSEC_CACHE_GUARD_TOKENS` | `50000` | Cache-loss guardrail (incident 2026-08-30): a warm lane about to rewrite more previously-covered tokens than this fails open to verbatim passthrough and latches until a fresh run. `0`/`off` disables. |
| `PARSEC_SCORE_MEMO_MAX` | `512` | Per-conversation score-memo entries (step + live-set fingerprint → scores). Makes post-reset birth replays HTTP-free . Min 1 = the old single-entry memo. |
| `PARSEC_SCORE_MEMO_PERSIST` | on | Persists the score memo to `~/.parsec/score_memo/` (hashes + quantized scores only — never text, never leaves the machine), so even post-RESTART/eviction replays are HTTP-free. Purged on brain checkpoint drift. `off` = in-memory only. |
| `PARSEC_INSTALL_REPORT` | on | `0` disables the anonymous install ping (install id, version, OS, arch, harness list — see README "What parsec sends"). `DO_NOT_TRACK=1` has the same effect. |
| `PARSEC_VERBOSE` | unset | `1` switches to the verbose tracing filter. |
| `PARSEC_RECORD_DIR` | unset | When set, every inbound request body is dumped verbatim to this dir (§8.1 capture seam; fail-open). |
| `PARSEC_FREEZE` | on | `off` is the master escape hatch: no brain config, passthrough curation. |
| `AC_CHUNK_MODE` | `fixed` | Engine chunking mode (`cst` opts into tree-sitter atoms). Client-side twin of the brain's pinned flag — leave alone in production; the ckpt was trained on `fixed`/10. Read in `packages/engine/src/chunking.rs`. |

## 1b. Client — first-run setup (`parsec setup`)

Read in `packages/proxy/src/setup.rs` and `hook.rs` (SessionStart). Setup is
spawned automatically on the first session after install; it downloads the
bge-large ONNX export, merges routing env into the user's Claude Code
settings (additive only — existing keys are never overwritten, a foreign
`ANTHROPIC_BASE_URL` is reported, not replaced), and pre-warms the proxy.
State lives in `~/.parsec/setup_state.json`; logs in `~/.parsec/setup.log`.
Undo with `parsec disable`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_AUTOSETUP` | on | `0` disables first-run auto-setup entirely (spawn and messaging). |
| `PARSEC_MODEL_BASE_URL` | unset (dev); baked release value | Directory URL serving `model.onnx` + `tokenizer.json`. Release builds bake `PARSEC_DEFAULT_MODEL_BASE_URL` at compile time (release.yml, from repo vars — must be the parity-gated export); the runtime var always wins and does NOT inherit the baked sha pins. |
| `PARSEC_MODEL_SHA256` | unset (dev); baked release value | sha256 pin for `model.onnx`; verified before the file is finalized, one clean re-download on mismatch. Unset ⇒ download unverified (dev only). |
| `PARSEC_TOKENIZER_SHA256` | unset (dev); baked release value | Same for `tokenizer.json`. |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's own config-relocation knob; setup honors it when writing `settings.json`. |

## 1c. Client — trim staging (`parsec trim`, `/parsec:trim`)

Read in `packages/proxy/src/trim.rs`; asserted by `tests/trim_cli.rs`. Full
user-facing doc: `docs/trim.md`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_TRIM_LEVEL` | `3` | Default aggressiveness 1 (low trimming) – 5 (very high) when no `--level`/skill argument is given. 3 is the only measured, parity-locked configuration. |
| `PARSEC_TRIM_TTL_SECS` | `1800` | Staged trim payloads expire after this many seconds (stale trims must never inject into unrelated work). |
| `PARSEC_TRIM_MAX_EST_TOKENS` | unset | Cap on the trim body's estimated (chars/4) tokens; staging refuses — never truncates — when exceeded. |

## 2. Client proxy — brain connection

Read in `packages/proxy/src/brain.rs` (`BrainConfig::from_env`).

| Var | Default | Effect |
|---|---|---|
| `PARSEC_BRAIN_URL` | unset (dev builds); baked production URL (release builds) | **The enable switch.** Release binaries carry a compile-time default (`PARSEC_DEFAULT_BRAIN_URL` stamped by release.yml → the production Cloud Run URL); the runtime var always overrides it, and setting it EMPTY disables the brain even on a release build. Dev/CI builds bake nothing: unset ⇒ no brain. |
| `PARSEC_BRAIN_CONTRACT` | `dev` (env URL) / `v1` (baked URL) | Only the exact string `v1` selects the textless client-featurized contract. When the URL comes from the baked release default, the contract defaults to v1 instead — a released binary is data-plane-clean by default. |
| `PARSEC_BRAIN_DEV_RAW` | unset | `1` is the **required opt-in** for the dev contract (raw internal text rides to the scoring host — only for a host you operate). Without it, a dev-contract brain URL is refused and curation stays passthrough. |
| `PARSEC_BRAIN_KEY` | unset | Bearer token sent to the brain (and checked by it, §6). Shared secret — coarse "reject anonymous scanners" filter, not per-user auth. |
| `PARSEC_BRAIN_TIMEOUT_MS` | `10000` | Per-request brain HTTP timeout. |
| `PARSEC_API_KEY` | unset | The user's per-account `psc_` key (minted at `app.getparsec.ai`). **The master entitlement gate: with NO key resolvable, parsec saves nothing** — the local hook (no-reread/loop-breaker) is inert, the backend is never called, and the proxy is a pure passthrough (Claude Code runs normally). A self-host `PARSEC_BRAIN_KEY` also satisfies the gate. The single source of truth is `apikey::resolve_key`/`enabled`. When set alongside a platform URL, each savings-ledger row is ALSO shipped to `/ledger` for per-user attribution. **The key arrives via `parsec login`** (browser handoff — see `docs/login-handoff.md`), which the install scripts, the native installers, the tray's *Sign in* item and the `/parsec:login` skill all run; a browserless machine stores a dashboard-minted key with `parsec key set <psc_…>`. Either way it lands in `~/.parsec/credentials.json` (0600), effective next request/session; this env var overrides that file. |
| `PARSEC_NO_LOGIN` | unset | `1` stops the installers (install.sh / install.ps1 / the macOS .pkg postinstall) from ending in the browser sign-in. For CI and scripted installs; a baked `--key` / `PARSEC_API_KEY` skips it on its own. `install.sh --no-login` and `install.ps1 -NoLogin` are the flag forms. |
| `PARSEC_DASHBOARD_URL` | unset → `https://app.getparsec.ai` | The dashboard origin `parsec login` opens (`/connect`) and accepts the key handoff from — the callback's `Origin` must match it. Set to `http://localhost:3000` when developing the frontend locally. Distinct from `PARSEC_PLATFORM_URL` (the API the proxy ships ledger rows to). |
| `PARSEC_API_KEY_NOTE` | unset | `0` silences the prominent "no API key — savings are OFF, get one at app.getparsec.ai" banner shown at SessionStart/install while unentitled. Silences the reminder only — it does NOT lift the gate. |
| `PARSEC_PLATFORM_URL` | unset (dev); baked release value | Platform base URL for savings-ledger shipping. Release binaries carry a compile-time default (`PARSEC_DEFAULT_PLATFORM_URL` stamped by release.yml); the runtime var overrides, empty disables. Shipping still requires `PARSEC_API_KEY`. |
| `PARSEC_TARGET_COV` | `0.70` | Serving coverage operating point requested from the brain. |
| `PARSEC_EMBED_BACKEND` | `hash` | v1-contract client embedder: `hash` (deterministic test vectors — warns, NOT trained bge) \| `remote` \| `onnx`. With the baked release URL, `hash` keeps the brain OFF entirely (garbage scores don't fail open the way HTTP errors do) — the baked default activates only once a real embedder is configured. |
| `PARSEC_EMBED_URL` | unset | Required for the `remote` embed backend. |
| `PARSEC_ONNX_DIR` | unset | Local bge-large export dir for the `onnx` backend (needs the `onnx` cargo feature; errors if compiled out). |

## 3. Client proxy — tool prune

Read in `packages/proxy/src/brain.rs`, applied in `server.rs`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_TOOL_PRUNE` | on (when brain configured) | `off` disables tool-schema pruning entirely. |
| `PARSEC_TOOL_CUT` | `0.70` | Rank-to-target cut fraction of roster token mass (AC_TOOL_CUT equivalent). |
| `PARSEC_TOOL_STUB` | on | Pruned custom tools are served as name+note stubs so the model knows they exist and can call one to restore its full schema (reactive unfreeze). `off` restores the reference hard-drop. Provider-typed tools are never stubbed. |

## 4. Client proxy — governor

Read in `packages/proxy/src/governor.rs` (`GovernorConfig::from_env`). All
dials are inert while the mode is `off`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_NOREREAD` | `off` | The no-reread / loop-breaker hook is **opt-in**. `on` (also `1`/`true`) arms it; anything else, unset included, leaves it fully inert — no denials, and no read/edit state recorded, so the savings ledger and statusline stay at zero. Inverted from `PARSEC_FREEZE=off` on purpose: this gate blocks a tool call the agent asked for, so off is the safe default. Stacks under `PARSEC_API_KEY` — both gates must be open. Every integration (Claude Code today; codex and opencode when their ports land) reads this one flag. |
| `PARSEC_GOVERNOR` | `off` | `off` \| `advise` (compute + ledger-record, wire untouched) \| `on` (directives injected). Also gates whether `gf` rides to the brain, i.e. whether the doomhead is scored at all. |
| `PARSEC_RULE_TAU` | `0.25` | Rule-head fire threshold (advisory calibration; bench-validated tau pending). |
| `PARSEC_DOOM_THRESH` | `0.5` | Doomhead flag threshold (reference proxy value). |
| `PARSEC_DOOM_K` | `3` | Consecutive dooms ≥ thresh required to flag. |
| `PARSEC_RUNAWAY_RATIO` | `3.25` | Billed-cum / neighbor-median kill knee (AC_RUNAWAY_RATIO). |
| `PARSEC_DOOMED_RATIO` | `2.0` | DOOMED advisory arm (AC_DOOMED_RATIO); advisory-only here. |
| `PARSEC_KILL_FLOOR_TOK` | `750000` | Billed input-token floor below which no kill arm may fire (token-denominated twin of AC_KILL_FLOOR_USD). |
| `PARSEC_HORIZON_STEP` | `0` (off) | Budget-horizon directive step (reference serve used 40). |

## 5. Client proxy — adjudicator (Stop hook)

Read in `packages/proxy/src/hook.rs`; logic in `adjudicator.rs`. Verdicts log
to `~/.parsec/adjudicator.jsonl`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_ADJUDICATOR` | `advise` | `off` \| `advise` (log only) \| `block` (may block a premature stop). Blocking is deliberately opt-in — the reference's block-on-CONTINUE overrode correct stops. |
| `PARSEC_ADJ_MAX_BLOCKS` | `2` | Per-session cap on blocked stops. |

## 6. Scoring service (`packages/brain`, Python)

Read in `packages/brain/src/parsec_brain/` (`bundle.py`, `scorer.py`,
`app.py`, `keyauth.py`, `_log.py`, `vendored/embedding.py`,
`vendored/local_embed.py`, `vendored/parsec_embed.py`). Self-hosting is
covered in `packages/brain/README.md`.

| Var | Default | Effect |
|---|---|---|
| `PARSEC_CKPT` | `~/.parsec/brain/curator_v4_prod.pt` | Checkpoint: a local path, or `hf://<org>/<repo>/<file>` fetched from the Hugging Face Hub (cached). The bundle self-validates shapes (incl. doom_head presence) and refuses to start on mismatch. |
| `PARSEC_RULES_JSON` | `<package>/models/rules.json` | Rule-head roster. |
| `AC_CHANGEPRONE_PKL` | `<package>/models/changeprone.pkl` | Readout col-42 sidecar; absent ⇒ zero-filled column. |
| `PARSEC_TARGET_COV` | `0.70` (falls back to `AC_TARGET_COV`) | Coverage the calibrated tau resolves. |
| `PARSEC_SERVE_TAU` | unset | Manual tau override — **demo/testing only**; leave unset for calibrated serving. |
| `PARSEC_HOODS_PKL` | unset | Neighborhood artifact for `/v1/neighbors`; unset ⇒ neighbors endpoint inert (governor runaway signal gets no median). |
| `PARSEC_NEIGHBORS` | `16` | Neighbors k. |
| `PARSEC_NEIGHBORS_X` | `2` | Trained expansion value — **do not change**. |
| `PARSEC_EMBED_BACKEND` | `local` | Server-side embedder: `local` (bge-large-en-v1.5 in-process, needs the `[embed]` extra) \| `remote` (an HTTP embed service you run, `PARSEC_EMBED_URL` required) \| `hash` (hermetic tests; scores meaningless). Note the different default from the proxy's client-side var of the same name. |
| `PARSEC_EMBED_MODEL_DIR` | unset | `local` backend: a directory holding the bge weights (e.g. baked into the image at `/embed-model`). Unset ⇒ the Hugging Face hub/cache. |
| `PARSEC_EMBED_URL` | unset | `remote` backend: the embedding service endpoint (`POST {"model_id","texts"} → {"vectors"}`). |
| `PARSEC_EMBED_MODEL` | `bge-large-en-v1.5` | `remote` backend: model id sent to the embed service. |
| `PARSEC_EMBED_BATCH` | `512` | `remote` backend: embed batch size (GPU amortization). |
| `PARSEC_EMBED_CACHE_MAX` | `100000` | Per-layer entry cap for the two server embed caches (scorer exact-text layer + embedder sha1 layer), evicted LRU with the in-flight batch pinned (`embed_cache.py`). `0`/`off` restores the unbounded cache-forever behavior. Pure cache: eviction can only cost a re-embed, never change a score. |
| `PARSEC_TORCH_THREADS` | unset | Pins `torch.set_num_threads` at startup — under cgroups torch reads the HOST core count and oversubscribes, so set it to the container's CPU limit. Unset = torch defaults. |
| `AC_EDGES_FAST` | on | Vectorized rel-0/rel-2 edge construction, bit-identical to the reference loops (pinned by `tests/test_edges_fast.py`). `off` restores the pure-Python scans. |
| `PARSEC_BRAIN_KEY` | unset | If set, bearer auth is required on every `/v1/*` endpoint (`/health` stays open). |
| `PARSEC_PLATFORM_URL` | unset | If set, takes precedence over `PARSEC_BRAIN_KEY`: every request's bearer is a per-user `psc_` key validated against `{url}/keys/validate/{key}` (must be valid AND entitled). The hosted service's seam; self-hosters leave it unset. |
| `PARSEC_BRAIN_AUTH_STRICT` | unset | `1` fails closed when the platform is unreachable; default serves and counts a fail-open. |
| `PARSEC_BRAIN_AUTH_TTL_S` | `300` | Cache lifetime of an entitled verdict (denials re-check after 30 s). |
| `PARSEC_BRAIN_AUTH_TIMEOUT_S` | `3` | Platform validation HTTP timeout. |
| `PARSEC_BRAIN_LOG` | `INFO` | Log level. |
| `PARSEC_BRAIN_LOG_JSON` | unset | `1` switches to JSON log lines. |

The `AC_*` graph-shape flags (`AC_CHUNK_MODE`, `AC_CHUNK_LINES`, `AC_HETGRAPH`,
…) are pinned by `_flags.py` to the values the checkpoint was trained under and
are not configuration; the effective snapshot is on `/v1/bundle`.

## Quick recipes

Default plugin install (free tier — no brain): nothing to set.

Pro-tier dev against a local brain (raw-text opt-in, dev machines only):

```sh
PARSEC_BRAIN_URL=http://127.0.0.1:8093 PARSEC_BRAIN_DEV_RAW=1
```

Data-plane-clean v1 with real embeddings:

```sh
PARSEC_BRAIN_URL=... PARSEC_BRAIN_CONTRACT=v1 PARSEC_EMBED_BACKEND=onnx PARSEC_ONNX_DIR=...
```

Governor shadow mode (score the doomhead, record, touch nothing):

```sh
PARSEC_GOVERNOR=advise
```

Reference-parity hard-drop tool prune (disable stubs):

```sh
PARSEC_TOOL_STUB=off
```
