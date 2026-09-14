# docs/

Architecture and integration notes. `DIRECTION.md` at the repository root is
the anchor; these go deeper on one subsystem each.

| Doc | What it covers |
|---|---|
| `freeze-design.md` | Deterministic quantized freezing: why served bytes are a pure function of the prefix, and how the fold/splice machinery keeps the provider cache warm. |
| `cache-continuity.md` | The cache-loss guardrail added after the 2026-08-30 incident and the `PARSEC_CACHE_GUARD_TOKENS` knob. |
| `trim.md` | `parsec trim` / `/parsec:trim`: the deterministic needed-set compaction and standing-directives block. |
| `inference-neighbor-data.md` | What the scoring request carries and why; the privacy boundary of the neighbour features. |
| `routing-and-liveness.md` | How harnesses are pointed at the proxy, autostart, idle exit, and the supervisor. |
| `session-scoped-proxy.md` | Per-session proxy instances and the port hand-off. |
| `login-handoff.md` | `parsec login`: the loopback sign-in flow the installers and `/parsec:login` use. |
| `claude-desktop-integration.md` | Intercepting Claude Desktop with a process-scoped mitmproxy addon. |
| `codex-integration.md` | Codex CLI routing. |
| `opencode-integration.md` | The OpenCode plugin shim. |
| `environment-variables.md` | Every env var the client reads, with defaults. |
| `release-channels.md` | Tag-driven release policy and the pre-release escape hatch. |

Some documents reference internal notes (incident write-ups, research
comparisons) that are not part of this repository; those links are left as
provenance.
