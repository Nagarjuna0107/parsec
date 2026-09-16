# Per-platform `parsec` binaries

Plugin distribution is git-clone → local cache copy with **no build or
postinstall step**, and the marketplace is this repository itself
(`.claude-plugin/marketplace.json` → `packages/plugin`). Binaries are not
committed: every `vX.Y.Z` tag publishes them as GitHub Release assets on
`daseinlabs/parsec` (`parsec-<platform>`, the win-x64 CRT DLLs, a
`manifest.json` of sha256s, `parsec-plugin.zip`, the native installers).

The shims resolve a binary in this order:

1. `bin/<platform>/parsec` beside the shim — `make plugin`
   (`scripts/refresh_plugin_bin.sh`) populates it for `--plugin-dir` testing,
   and `parsec-plugin.zip` ships it prebuilt. Gitignored in the source tree.
2. `~/.parsec/bin/parsec` — the stable path `install.sh` / `install.ps1` and
   the native installers write. At `hook SessionStart` its `--version` is
   compared with `.claude-plugin/plugin.json`; an older binary is upgraded
   from the matching GitHub Release, so a marketplace plugin update brings
   its binary along.
3. Neither: the shim downloads the plugin's version from GitHub Releases
   (sha256-verified against that release's `manifest.json`) into
   `~/.parsec/bin` and runs it. `PARSEC_RELEASE_BASE` redirects the download
   for tests.

```
bin/
  darwin-arm64/parsec   (gitignored; dev builds and the release zip)
  darwin-x64/parsec
  linux-x64/parsec
  win-x64/parsec.exe
  parsec          ← sh shim: platform select, alias refresh, release bootstrap
  parsec.cmd      ← Windows shim, same order
  bootstrap.ps1   ← the Windows download/upgrade step parsec.cmd calls
```

Built from `packages/proxy` (`cargo build --release --bin parsec`). The shims
are the only non-Rust client code in the product.

Free-tier v0 may ship with only the `mcp` + `hook` subcommands implemented;
`proxy` lands with the Pro tier (DIRECTION.md §7b sequencing guard).

The Pro-tier `proxy` subcommand is a **supervisor**: it owns the routed
loopback port (`ANTHROPIC_BASE_URL`) and spawns/restarts a hidden
`proxy-worker` that does the curation. If the worker crashes or wedges, the
supervisor forwards requests straight to Anthropic — so a session never
stalls on a dead proxy — then respawns the worker. `proxy-worker` is an
implementation detail of `proxy`, never launched by hand.
