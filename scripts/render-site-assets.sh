#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.02, AC-28.04.
# Renders every product picture in docs/assets/screenshots from Lunlet's real views with synthetic data
# (SiteAssetRenderTests); the README and the product page show these files. Nothing is recorded from the screen.
# Usage: scripts/render-site-assets.sh
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

stills=$(mktemp -d "${TMPDIR:-/tmp}/lunlet-stills.XXXXXX")
trap 'rm -rf "$stills"' EXIT
LUNLET_SITE_ASSET_DIR="$stills" scripts/test-core.sh --filter SiteAssetRenderTests
if [ ! -f "$stills/hero-overview.png" ]; then
    echo "render-site-assets: the still render test produced no pictures" >&2
    exit 1
fi

out=docs/assets/screenshots
mkdir -p "$out"
# Interface-only pictures stay PNG; pictures of the synthetic display carry its wallpaper, so they ship as JPEG.
for name in notch notch-lanterns phone-notice phone-replied phone-delivered; do
    cp "$stills/$name.png" "$out/$name.png"
done
for name in hero-overview cue-island panel-codex panel-overview panel-claude; do
    sips -s format jpeg -s formatOptions 84 "$stills/$name.png" --out "$out/$name.jpg" >/dev/null
done
ls -l "$out"
