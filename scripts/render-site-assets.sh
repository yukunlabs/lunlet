#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.02, AC-28.04.
# Renders every product picture in docs/assets/screenshots from Lunlet's real views with synthetic data
# (SiteAssetRenderTests); the README and the product page show these files. Nothing is recorded from the screen.
# The stills' manifest records the sources they were drawn from; when it already matches, nothing is rendered.
# Usage: scripts/render-site-assets.sh [--force]
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${1:-}" != "--force" ] && python3 scripts/check_site_assets.py --stills --quiet; then
    echo "render-site-assets: the stills already match the current sources (pass --force to render them again)"
    exit 0
fi

stills=$(mktemp -d "${TMPDIR:-/tmp}/lunlet-stills.XXXXXX")
trap 'rm -rf "$stills"' EXIT
LUNLET_SITE_ASSET_DIR="$stills" scripts/test-core.sh --filter SiteAssetRenderTests
if [ ! -f "$stills/hero-overview.png" ]; then
    echo "render-site-assets: the still render test produced no pictures" >&2
    exit 1
fi

out=docs/assets/screenshots
mkdir -p "$out"
# The render names each picture after the sources' own identifiers (agents, skins, messengers); pictures that are no
# longer rendered leave with it. Interface-only pictures stay PNG; pictures of the synthetic display carry its
# wallpaper, so they ship as JPEG.
find "$out" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' \) -delete
for still in "$stills"/*.png; do
    name=$(basename "$still" .png)
    case "$name" in
        hero-overview|cue-island|panel-*) sips -s format jpeg -s formatOptions 84 "$still" --out "$out/$name.jpg" >/dev/null ;;
        *) cp "$still" "$out/$name.png" ;;
    esac
done
python3 scripts/check_site_assets.py --stills --write
ls -l "$out"
