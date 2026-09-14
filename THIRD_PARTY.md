# Third-party notices

parsec is MIT licensed (see `LICENSE`). It includes or derives from the
following third-party work.

## CC-Router (MIT)

The Claude Desktop interception approach in `packages/proxy/src/desktop_addon.py`
and the matching setup logic in `packages/proxy/src/setup_desktop.rs` follow
[CC-Router](https://github.com/VictorMinemu/CC-Router)'s mitmproxy interceptor.

    MIT License
    Copyright (c) 2026 CC-Router Contributors

## JetBrains Mono (SIL Open Font License 1.1)

`packages/installer/assets/fonts/JetBrainsMono-*.ttf` are bundled in the native
installers under the OFL; the license text ships beside them at
`packages/installer/assets/fonts/OFL.txt`.

## Contributor Covenant (CC BY 4.0)

`CODE_OF_CONDUCT.md` is adapted from Contributor Covenant 2.1.

## Rust and Python dependencies

Crate licenses are enforced in CI by `cargo deny` against the allow list in
`deny.toml`. Python helpers (parity generators, the mock upstream, the
mitmproxy addon) use only the standard library plus what their headers import.

## Trademarks

"parsec" and the parsec logo are trademarks of Dasein Labs. The MIT license
covers the code, not the name or the logo: you may fork and redistribute the
software, but please do not present a modified build as an official parsec
release or use the logo in a way that implies endorsement.
