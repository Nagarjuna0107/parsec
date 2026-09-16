#!/usr/bin/env bash
# Compatibility stub — this URL shipped in earlier releases and must keep
# working. The real installer is install.sh (auto-detects codex + opencode);
# this forwards to it pinned to opencode. Both scripts live beside each other
# in the daseinlabs/parsec tree; PARSEC_INSTALL_BASE is where to fetch
# install.sh from (a raw-content URL for the scripts directory).
set -euo pipefail
BASE="${PARSEC_INSTALL_BASE:-https://raw.githubusercontent.com/daseinlabs/parsec/main/scripts}"
curl -fsSL "$BASE/install.sh" | bash -s -- opencode
