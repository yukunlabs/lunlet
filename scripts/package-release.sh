#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.01, AC-27.03; US-29, AC-29.01, AC-29.03; US-35, AC-35.01, AC-35.04.
# Package an already signed, notarized candidate, or with LUNLET_RELEASE_UNSIGNED=1 an unsigned preview release whose
# ad hoc signature is verified and recorded as such (AC-27.05). Never signs, submits or publishes.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
lunlet_app=${1:-}
lunlet_tag=${2:-}
if [ "$#" -ne 2 ] || [ ! -d "$lunlet_app/Contents" ]; then
    printf '%s\n' 'Usage: scripts/package-release.sh /absolute/Lunlet.app vMAJOR.MINOR.PATCH' >&2
    exit 2
fi
case "$lunlet_app" in /*) ;; *) printf '%s\n' 'The application path must be absolute.' >&2; exit 2 ;; esac
if ! printf '%s\n' "$lunlet_tag" | /usr/bin/grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    printf '%s\n' 'Use a version tag such as v0.1.0.' >&2; exit 2
fi
# Freeze the candidate before inspecting it; concurrent rebuilds cannot change
# the bytes validated below or the application later added to the archive.
mkdir -p "$PWD/.tmp"
lunlet_stage=$(mktemp -d "$PWD/.tmp/lunlet-release-stage.XXXXXX")
lunlet_final_output=
lunlet_finished=false
trap 'rm -rf "$lunlet_stage"; if [ "$lunlet_finished" = false ] && [ -n "$lunlet_final_output" ]; then rm -rf "$lunlet_final_output"; fi' EXIT
trap 'exit 130' HUP INT TERM
/usr/bin/ditto "$lunlet_app" "$lunlet_stage/Lunlet.app"
lunlet_app="$lunlet_stage/Lunlet.app"
lunlet_plist="$lunlet_app/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :LunletDevelopmentPreview' "$lunlet_plist" 2>/dev/null | /usr/bin/grep -qx true; then
    printf '%s\n' 'Development previews cannot become public release artifacts.' >&2; exit 2
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$lunlet_plist")" != com.lunlet ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$lunlet_plist")" != "${lunlet_tag#v}" ]; then
    printf '%s\n' 'The bundle identity/version must match the release tag.' >&2; exit 2
fi
lunlet_revision=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse "refs/tags/$lunlet_tag^{commit}")" != "$lunlet_revision" ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :LunletSourceRevision' "$lunlet_plist")" != "$lunlet_revision" ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :LunletSourceDirty' "$lunlet_plist")" != false ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :LunletBuildConfiguration' "$lunlet_plist")" != release ]; then
    printf '%s\n' 'A clean checkout at the matching source tag is required.' >&2; exit 2
fi
if [ ! -s LICENSE ] || [ ! -s NOTICE.md ] ||
   ! cmp -s LICENSE "$lunlet_app/Contents/Resources/third-party/lunlet-license.txt" ||
   ! cmp -s NOTICE.md "$lunlet_app/Contents/Resources/third-party/NOTICE.md" ||
   ! cmp -s Resources/third-party/swift-protobuf-license.txt "$lunlet_app/Contents/Resources/third-party/swift-protobuf-license.txt" ||
   ! cmp -s Resources/third-party/sparkle-license.txt "$lunlet_app/Contents/Resources/third-party/sparkle-license.txt"; then
    printf '%s\n' 'Owner-approved project licensing and matching packaged notices are required.' >&2; exit 2
fi
lunlet_unsigned=${LUNLET_RELEASE_UNSIGNED:-}
if [ "$lunlet_unsigned" != 1 ] && [ -z "${LUNLET_RELEASE_TEAM_ID:-}" ]; then
    printf '%s\n' 'Set LUNLET_RELEASE_TEAM_ID to the owner-approved stable signing team, or LUNLET_RELEASE_UNSIGNED=1 for an unsigned preview release.' >&2; exit 2
fi
/usr/bin/codesign --verify --deep --strict "$lunlet_app"
lunlet_signature=$(/usr/bin/codesign -d --verbose=4 "$lunlet_app" 2>&1)
if [ "$lunlet_unsigned" = 1 ]; then
    # An unsigned preview is exactly an ad hoc signature: no certificate, no team, no notarization to validate. Its
    # release notes carry the first-open steps (AC-27.05).
    if ! printf '%s\n' "$lunlet_signature" | /usr/bin/grep -q '^Signature=adhoc$' ||
       printf '%s\n' "$lunlet_signature" | /usr/bin/grep -q '^Authority='; then
        printf '%s\n' 'An unsigned preview release must carry an ad hoc signature and no certificate.' >&2; exit 2
    fi
    lunlet_signing_label='ad hoc (unsigned preview)'
    lunlet_notarization_label='none (unsigned preview; macOS asks to allow the app on first open)'
else
    if ! printf '%s\n' "$lunlet_signature" | /usr/bin/grep -q '^Authority=Developer ID Application:' ||
       [ "$(printf '%s\n' "$lunlet_signature" | /usr/bin/sed -n 's/^TeamIdentifier=//p')" != "$LUNLET_RELEASE_TEAM_ID" ]; then
        printf '%s\n' 'A stable Developer ID Application signature is required.' >&2; exit 2
    fi
    /usr/bin/xcrun stapler validate "$lunlet_app"
    /usr/sbin/spctl --assess --type execute --verbose "$lunlet_app"
    lunlet_signing_label='Developer ID Application'
    lunlet_notarization_label='stapled ticket validated'
fi
# The hardened runtime belongs to certificate-signed candidates only: notarization needs it, while an ad hoc
# signature has no team identifier and the runtime's library validation would refuse the embedded Sparkle framework
# at launch (found on the first unsigned candidate, 2026-11-01).
if printf '%s\n' "$lunlet_signature" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime'; then
    if [ "$lunlet_unsigned" = 1 ]; then
        printf '%s\n' 'An ad hoc signed candidate must not use the hardened runtime: it could not load its own frameworks.' >&2; exit 2
    fi
elif [ "$lunlet_unsigned" != 1 ]; then
    printf '%s\n' 'The candidate requires hardened runtime.' >&2; exit 2
fi
lunlet_archs=$(/usr/bin/lipo -archs "$lunlet_app/Contents/MacOS/Lunlet")
case "$lunlet_archs" in arm64) lunlet_arch_label=arm64 ;; x86_64) lunlet_arch_label=x86_64 ;; 'x86_64 arm64'|'arm64 x86_64') lunlet_arch_label=universal ;; *) printf '%s\n' 'Unsupported binary architectures.' >&2; exit 2 ;; esac
mkdir -p "$lunlet_stage/artifacts"
lunlet_output="$lunlet_stage/artifacts"
lunlet_archive="Lunlet-${lunlet_tag#v}-macos-$lunlet_arch_label.zip"
lunlet_image="Lunlet-${lunlet_tag#v}-macos-$lunlet_arch_label.dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$lunlet_app" "$lunlet_output/$lunlet_archive"
# The disk image is what people download: the app beside an Applications link, read-only and compressed. The ZIP
# beside it is what the update feed serves. Both carry the same bytes of the same candidate.
mkdir -p "$lunlet_stage/image"
/usr/bin/ditto "$lunlet_app" "$lunlet_stage/image/Lunlet.app"
ln -s /Applications "$lunlet_stage/image/Applications"
/usr/bin/hdiutil create -quiet -volname Lunlet -srcfolder "$lunlet_stage/image" -ov -format UDZO "$lunlet_output/$lunlet_image"
cp "$lunlet_app/Contents/Resources/third-party/lunlet-license.txt" "$lunlet_output/LICENSE"
cp "$lunlet_app/Contents/Resources/third-party/NOTICE.md" "$lunlet_output/NOTICE.md"
LUNLET_RELEASE_IMAGE="$lunlet_image" LUNLET_RELEASE_ARCHIVE="$lunlet_archive" LUNLET_RELEASE_SIGNING="$lunlet_signing_label" LUNLET_RELEASE_NOTARIZATION="$lunlet_notarization_label" LUNLET_RELEASE_REVISION="$lunlet_revision" LUNLET_RELEASE_OUTPUT="$lunlet_output" LUNLET_RELEASE_TAG="$lunlet_tag" LUNLET_RELEASE_ARCHS="$lunlet_archs" LUNLET_RELEASE_APP="$lunlet_app" python3 - <<'PY'
import json, os, plistlib
from pathlib import Path
app = Path(os.environ['LUNLET_RELEASE_APP'])
with (app / 'Contents/Info.plist').open('rb') as file:
    info = plistlib.load(file)
manifest = {
    'tag': os.environ['LUNLET_RELEASE_TAG'],
    'sourceRevision': os.environ['LUNLET_RELEASE_REVISION'],
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'deploymentTarget': info['LSMinimumSystemVersion'],
    'architectures': os.environ['LUNLET_RELEASE_ARCHS'].split(),
    'download': os.environ['LUNLET_RELEASE_IMAGE'],
    'updateArchive': os.environ['LUNLET_RELEASE_ARCHIVE'],
    'signing': os.environ['LUNLET_RELEASE_SIGNING'],
    'notarization': os.environ['LUNLET_RELEASE_NOTARIZATION'],
    # Reviewers see whether this candidate checks for updates, and where (AC-35.01, AC-35.04).
    'updateFeed': info.get('SUFeedURL')
}
(Path(os.environ['LUNLET_RELEASE_OUTPUT']) / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
(
    cd "$lunlet_output"
    /usr/bin/shasum -a 256 "$lunlet_image" "$lunlet_archive" LICENSE NOTICE.md manifest.json > SHA256SUMS
)
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$lunlet_revision" ] ||
   [ "$(git rev-parse "refs/tags/$lunlet_tag^{commit}")" != "$lunlet_revision" ] ||
   ! cmp -s LICENSE "$lunlet_output/LICENSE" || ! cmp -s NOTICE.md "$lunlet_output/NOTICE.md"; then
    printf '%s\n' 'Source or notices changed during packaging. No candidate was published.' >&2; exit 2
fi
# Reserve a unique final directory atomically. Concurrent candidates can never
# overwrite or become nested inside a previously reviewed candidate.
mkdir -p "$PWD/.tmp/releases"
lunlet_final_output=$(mktemp -d "$PWD/.tmp/releases/$lunlet_tag.XXXXXX")
mv "$lunlet_output"/* "$lunlet_final_output/"
lunlet_finished=true
printf '%s\n' "$lunlet_final_output" 'Prepared locally. Review release notes and clean-machine install/update evidence before publication.'
