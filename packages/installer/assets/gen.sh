#!/usr/bin/env bash
# Regenerate every raster the native installers ship, from the brand kit.
#
#   packages/installer/assets/gen.sh
#
# Outputs are COMMITTED (CI never runs this): the macOS pane backgrounds under
# packages/installer/macos/resources/ and the Windows wizard images + .ico
# under packages/installer/windows/assets/. Run it again whenever
# brand/parsecbrandkit changes. Needs ImageMagick 7 (`brew install
# imagemagick`); fonts are vendored beside this script (JetBrains Mono, OFL).
#
# Brand rules applied (brand/parsecbrandkit/BRANDING.md): the mark is never
# rotated, stretched, or recolored per-campaign — the only recolor is the
# sanctioned `#2FA317` for light backgrounds. Wordmark and copy are JetBrains
# Mono; the Windows images sit on the void `#0A0E0C` because Inno's wizard is
# themed dark to match, while the macOS panes ship bare marks because
# Installer.app owns the (light or dark) pane behind them.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BRAND="$ROOT/brand/parsecbrandkit"
FONT_BOLD="$HERE/fonts/JetBrainsMono-Bold.ttf"
FONT_REG="$HERE/fonts/JetBrainsMono-Regular.ttf"
MAC="$ROOT/packages/installer/macos/resources"
WIN="$ROOT/packages/installer/windows/assets"

VOID="#0A0E0C"
PHOSPHOR="#4AF626"
GREEN_LIGHT="#2FA317"
TEXT="#D7FBE4"
MUTED="#8CA897"

command -v magick >/dev/null || { echo "ImageMagick 7 (magick) is required" >&2; exit 1; }
[ -f "$FONT_BOLD" ] && [ -f "$FONT_REG" ] || { echo "fonts missing under $HERE/fonts" >&2; exit 1; }
mkdir -p "$MAC" "$WIN"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── marks ────────────────────────────────────────────────────────────────────
# Light-background mark: the flat PNG (transparent, one colour) with its one
# sanctioned recolor. Recolored as a raster rather than rasterized from the
# SVG: ImageMagick's built-in SVG renderer drops the stroked sightlines and
# leaves only the star.
magick "$BRAND/logo/png/parsec-mark-flat.png" -fill "$GREEN_LIGHT" -colorize 100% "$tmp/mark-light.png"
# Installer.app places PNGs at pixel size, so the pane backgrounds are 1×:
# 260×160 is the mark's native box.
magick "$tmp/mark-light.png" -resize 260x160 "$MAC/background.png"
magick "$BRAND/logo/png/parsec-mark-glow.png" -resize 260x160 "$MAC/background-dark.png"
# The same marks, larger, for the HTML panes (2× for Retina; sized by CSS).
magick "$tmp/mark-light.png" -resize 520x320 "$MAC/mark-light.png"
magick "$BRAND/logo/png/parsec-mark-glow.png" -resize 520x320 "$MAC/mark-dark.png"

# ── Windows wizard side image ────────────────────────────────────────────────
# Inno 6.6+ picks the best of several sizes for the DPI in use; the aspect
# must stay exactly 202:386 (the 100% image area). Mark in the upper third,
# wordmark + tagline below, everything on the void.
side() { # width height mark_w mark_y word_pt word_y tag_pt tag_y out
  local w=$1 h=$2 mw=$3 my=$4 wpt=$5 wy=$6 tpt=$7 ty=$8 out=$9
  magick -size "${w}x${h}" "xc:$VOID" \
    \( "$BRAND/logo/png/parsec-mark-glow.png" -resize "${mw}x" \) -gravity north -geometry "+0+${my}" -composite \
    -font "$FONT_BOLD" -pointsize "$wpt" -fill "$PHOSPHOR" -gravity north -annotate "+0+${wy}" "parsec" \
    -font "$FONT_REG" -pointsize "$tpt" -fill "$TEXT" -gravity north -annotate "+0+${ty}" "2× the context." \
    -font "$FONT_REG" -pointsize "$tpt" -fill "$TEXT" -gravity north -annotate "+0+$((ty + tpt + tpt / 2))" "½ the cost." \
    -font "$FONT_REG" -pointsize $((tpt * 3 / 4)) -fill "$MUTED" -gravity south -annotate "+0+$((tpt))" "getparsec.ai" \
    "$out"
}
side 202 386  150 60  30 160 13 210 "$WIN/wizard-side-202x386.png"
side 336 643  250 100 50 266 22 350 "$WIN/wizard-side-336x643.png"
side 534 1022 396 160 80 424 34 556 "$WIN/wizard-side-534x1022.png"

# ── Windows wizard small image (header, right side) ─────────────────────────
# The rounded dark app tile carries the mark at small sizes.
for s in 58 97 159; do
  magick "$BRAND/logo/png/parsec-icon-512.png" -resize "${s}x${s}" "$WIN/wizard-small-${s}.png"
done

# ── Windows .ico (Setup, Add/Remove Programs, the uninstaller) ──────────────
# The hand-tuned favicons at 16/32/64 (thicker strokes for tiny sizes), the
# app tile for 48 and 256.
magick "$BRAND/logo/png/parsec-favicon-16.png" \
       "$BRAND/logo/png/parsec-favicon-32.png" \
       \( "$BRAND/logo/png/parsec-icon-1024.png" -resize 48x48 \) \
       "$BRAND/logo/png/parsec-favicon-64.png" \
       \( "$BRAND/logo/png/parsec-icon-1024.png" -resize 256x256 \) \
       "$WIN/parsec.ico"

echo "wrote:"
ls -1 "$MAC"/*.png "$WIN"/*.png "$WIN"/*.ico
