#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.01, AC-27.03; US-29, AC-29.01, AC-29.03; US-35, AC-35.01, AC-35.02, AC-35.04.
# Package an already signed, notarized candidate, or with LUNLET_RELEASE_UNSIGNED=1 an unsigned preview release whose
# ad hoc signature is verified and recorded as such (AC-27.05). Never signs, submits or publishes.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Every installed copy since v0.1.0 reads this feed and accepts only updates signed for this public key
# (docs/releases.md). A release carrying anything else could never be updated again, so these are not parameters.
lunlet_release_feed='https://github.com/yukunlabs/lunlet/releases/latest/download/appcast.xml'
lunlet_release_key='EhftNv8sxDPjDmCQ+FELNAg9SlWVuHMTGpYU29qJwAg='
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
# The debug symbols scripts/build-app.sh wrote beside the bundle are frozen with it.
lunlet_app=${lunlet_app%/}
lunlet_candidate_symbols="${lunlet_app%.app}.dSYMs"
if [ -d "$lunlet_candidate_symbols" ]; then
    /usr/bin/ditto "$lunlet_candidate_symbols" "$lunlet_stage/dSYMs"
fi
lunlet_app="$lunlet_stage/Lunlet.app"
lunlet_plist="$lunlet_app/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :LunletDevelopmentPreview' "$lunlet_plist" 2>/dev/null | /usr/bin/grep -qx true; then
    printf '%s\n' 'Development previews cannot become public release artifacts.' >&2; exit 2
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$lunlet_plist")" != com.lunlet ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$lunlet_plist")" != "${lunlet_tag#v}" ]; then
    printf '%s\n' 'The bundle identity/version must match the release tag.' >&2; exit 2
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$lunlet_plist" 2>/dev/null || true)" != "$lunlet_release_feed" ]; then
    printf '%s\n' "The candidate's update feed is not $lunlet_release_feed; copies installed from it could never update." >&2
    printf '%s\n' 'Rebuild with LUNLET_UPDATE_FEED_URL and LUNLET_UPDATE_PUBLIC_KEY as docs/releases.md records them.' >&2; exit 2
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$lunlet_plist" 2>/dev/null || true)" != "$lunlet_release_key" ]; then
    printf '%s\n' "The candidate's update key is not the one installed copies trust; copies installed from it could never update." >&2
    printf '%s\n' 'Rebuild with LUNLET_UPDATE_FEED_URL and LUNLET_UPDATE_PUBLIC_KEY as docs/releases.md records them.' >&2; exit 2
fi
# The appcast offers an update by build number, so it must be a whole number above every other release's.
lunlet_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$lunlet_plist")
if ! printf '%s\n' "$lunlet_build" | /usr/bin/grep -Eqx '[1-9][0-9]{0,8}'; then
    printf '%s\n' 'The build number (CFBundleVersion) must be a whole number.' >&2; exit 2
fi
lunlet_release_tags=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*')
for lunlet_other_tag in $lunlet_release_tags; do
    [ "$lunlet_other_tag" = "$lunlet_tag" ] && continue
    git show "$lunlet_other_tag:Resources/Info.plist" > "$lunlet_stage/other-info.plist"
    lunlet_other_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$lunlet_stage/other-info.plist")
    if ! printf '%s\n' "$lunlet_other_build" | /usr/bin/grep -Eqx '[0-9]{1,9}' || [ "$lunlet_build" -le "$lunlet_other_build" ]; then
        printf '%s\n' "The build number $lunlet_build must be greater than $lunlet_other_tag's ($lunlet_other_build), or no installed copy is offered this release." >&2
        printf '%s\n' 'Raise CFBundleVersion in Resources/Info.plist, commit and tag again.' >&2; exit 2
    fi
done
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
# Nothing published names the build Mac, and what was removed stays readable (AC-27.03): each executable is without
# debug symbols, searches only the bundle and the system Swift runtime, and has its own dSYM beside the candidate.
lunlet_build_identifiers() {
    lunlet_identifier_listing=$(/usr/bin/dwarfdump --uuid "$1")
    printf '%s\n' "$lunlet_identifier_listing" | /usr/bin/awk '$1 == "UUID:" { print $2, $3 }' | /usr/bin/sort
}
for lunlet_executable in "$lunlet_app"/Contents/MacOS/*; do
    [ -f "$lunlet_executable" ] || continue
    lunlet_name=$(basename "$lunlet_executable")
    lunlet_symbol_table=$(/usr/bin/nm -a "$lunlet_executable")
    # `strip` leaves one debug-style entry of its own in a Swift executable, a fixed marker that names nothing.
    if printf '%s\n' "$lunlet_symbol_table" | /usr/bin/grep -E '^[0-9a-f]+ +- ' | /usr/bin/grep -Evq ' OPT radr://5614542$'; then
        printf '%s\n' "$lunlet_name still carries debug symbols, which name the build Mac's paths. Build the candidate with scripts/build-app.sh." >&2; exit 2
    fi
    lunlet_load_commands=$(/usr/bin/otool -l "$lunlet_executable")
    lunlet_foreign_path=$(printf '%s\n' "$lunlet_load_commands" | /usr/bin/sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' |
        /usr/bin/grep -Ev '^(@|/usr/lib/swift$)' | /usr/bin/head -n 1 || true)
    if [ -n "$lunlet_foreign_path" ]; then
        printf '%s\n' "$lunlet_name has the search path $lunlet_foreign_path, which is outside the bundle. Build the candidate with scripts/build-app.sh." >&2; exit 2
    fi
    lunlet_identifiers=$(lunlet_build_identifiers "$lunlet_executable")
    if [ -z "$lunlet_identifiers" ] || [ ! -d "$lunlet_stage/dSYMs/$lunlet_name.dSYM" ] ||
       [ "$(lunlet_build_identifiers "$lunlet_stage/dSYMs/$lunlet_name.dSYM")" != "$lunlet_identifiers" ]; then
        printf '%s\n' "No dSYM of this build of $lunlet_name is beside the candidate (expected $lunlet_candidate_symbols/$lunlet_name.dSYM); its crash reports could not be read." >&2; exit 2
    fi
done
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
# Kept with the candidate for reading crash reports; they name the build Mac's paths and are not release assets.
mv "$lunlet_stage/dSYMs" "$lunlet_final_output/dSYMs"
lunlet_finished=true
printf '%s\n' "$lunlet_final_output" 'Prepared locally. Review release notes and clean-machine install/update evidence before publication.' \
    'The dSYMs folder holds the debug symbols for crash reports: keep it with the candidate and do not attach it to the release.'
