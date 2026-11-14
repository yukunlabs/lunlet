#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.02; US-34, AC-34.02, AC-34.03.
#
# Runs the repository's own checks, the same on a developer's Mac and in the hosted workflow: the areas named as
# arguments, or all of them. The Swift modules have their own entry, scripts/test-core.sh.
#
#   scripts/check-repository.sh [requirements] [page] [hygiene] [release]
set -eu
cd "$(dirname "$0")/.."

unit() { python3 -m unittest discover -s scripts -p "$1"; }

# Stories, criteria and the references to them; the language rule and the README's translations.
requirements() {
    unit test_traceability.py
    python3 scripts/check_traceability.py
}

# The product page builds from the confirmed stories and the sources, and its pictures match them.
page() {
    unit test_site.py
    node --check website/app.js
    site=$(mktemp -d)
    python3 scripts/build_site.py --output "$site/site"
    rm -rf "$site"
    python3 scripts/check_site_assets.py
}

# The tree itself: whitespace, test waits, test settings, private data, and the rules that pick the slow areas.
hygiene() {
    # A clean checkout has no working-tree changes, so the committed tree is compared with the empty tree; the
    # second line covers a developer's uncommitted work. Upstream license texts keep their own whitespace.
    git diff --check "$(git hash-object -t tree /dev/null)" HEAD -- . ':(exclude)Resources/third-party'
    git diff --check HEAD -- . ':(exclude)Resources/third-party'
    unit test_test_waits.py
    python3 scripts/check_test_waits.py
    unit test_test_settings.py
    python3 scripts/check_test_settings.py
    unit test_private_data.py
    python3 scripts/check_private_data.py
    unit test_changed_areas.py
}

# Packaging and the update feed; these sign and inspect synthetic bundles with the system's tools, so macOS only.
release() {
    unit test_release.py
    unit test_appcast.py
}

[ "$#" -gt 0 ] || set -- requirements page hygiene release
for area in "$@"; do
    case "$area" in
        requirements|page|hygiene|release) printf '== %s\n' "$area"; "$area" ;;
        *) printf 'Unknown area: %s\n' "$area" >&2; exit 2 ;;
    esac
done
