# Changelog

All notable changes to parsec are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Releases are tagged `vX.Y.Z`. Prebuilt binaries and installers for each tag
are published on the releases page.

## [Unreleased]

## [0.2.18] - 2026-09-15

First release cut from the public repository.

### Added
- The proxy, engine, mapgen, contracts, plugins, installers, and the scoring
  service (`packages/brain`) now develop in the open under MIT.
- `PARSEC_INSTALL_REPORT=0` (or `DO_NOT_TRACK=1`) disables the anonymous
  install ping. The README's "What parsec sends" section lists every byte
  that leaves the machine and its off switch.
- The scoring service loads its checkpoint from a local path, a Hugging Face
  id (`hf://`), or a GCS mirror, and defaults to the in-process embedder.

### Changed
- Plugin and marketplace descriptions no longer reference internal product
  names.
- `packages/brain`, the scoring service, is now in the open repository and
  self-hostable: `docker compose up -d` plus `PARSEC_BRAIN_URL`.
  `PARSEC_CKPT=hf://<org>/<repo>/<file>` pulls a checkpoint from the Hugging
  Face Hub. The remote-embedder backend is now named `remote` (was an
  internal service name) and the in-process `local` encoder is the default.

## [0.2.17] - 2026-09-13

Last release cut from the private repository. See the release notes on the
releases page for the history before this point.
