#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-02, AC-02.04, AC-02.07.
# Refs: US-01, AC-01.01, AC-01.02; US-03, AC-03.04; US-12, AC-12.04.
# Refs: US-27, AC-27.03; US-29, AC-29.01, AC-29.03.
# Refs: US-35, AC-35.01, AC-35.02, AC-35.04.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
lunlet_preview=false
lunlet_configuration=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --preview) lunlet_preview=true; shift ;;
        -c|--configuration)
            if [ "$#" -lt 2 ]; then printf '%s\n' 'A build configuration is required.' >&2; exit 2; fi
            case "$2" in debug|release) lunlet_configuration=$2 ;; *) printf '%s\n' 'Use debug or release.' >&2; exit 2 ;; esac
            shift 2 ;;
        --help)
            printf '%s\n' 'Usage: scripts/build-app.sh [--preview] [--configuration debug|release]'
            exit 0 ;;
        *) printf '%s\n' 'Unsupported build option. Only --preview and --configuration are accepted.' >&2; exit 2 ;;
    esac
done
if [ -z "$lunlet_configuration" ]; then
    if [ "$lunlet_preview" = true ]; then lunlet_configuration=debug; else lunlet_configuration=release; fi
fi
if [ "$lunlet_preview" = false ] && [ "$lunlet_configuration" != release ]; then
    printf '%s\n' 'Normal distribution builds require the release configuration.' >&2; exit 2
fi
lunlet_signing_identity=${LUNLET_CODE_SIGN_IDENTITY:-}
if [ "$lunlet_preview" = true ]; then
    # A preview signs with a named local development certificate so every rebuild keeps the same identity and the
    # saved Feishu enrollment stays readable without a Keychain prompt; without one it
    # is signed ad hoc, and each build needs Authorize access once.
    if [ -z "$lunlet_signing_identity" ]; then lunlet_signing_identity=-; fi
elif [ "$lunlet_signing_identity" = - ] && [ "${LUNLET_RELEASE_UNSIGNED:-}" = 1 ]; then
    # The unsigned preview release (owner decision 2026-11-01): a release build signed ad hoc, so macOS asks to allow it
    # on first open; credentials live in Lunlet's user-only file, so updates ask for nothing. Its notes must say so (AC-27.05).
    printf '%s\n' 'Building an unsigned preview release; its notes must state the first-open steps.' >&2
elif [ -z "$lunlet_signing_identity" ] || [ "$lunlet_signing_identity" = - ]; then
    printf '%s\n' 'A normal Lunlet build requires a certificate signing identity.' >&2
    printf '%s\n' 'Set LUNLET_CODE_SIGN_IDENTITY (or LUNLET_CODE_SIGN_IDENTITY=- with LUNLET_RELEASE_UNSIGNED=1 for an unsigned preview release), or use --preview for a development build with explicit owner authorization for saved Feishu access.' >&2
    exit 2
fi
# Release builds take the owner's update feed and public EdDSA key from the environment, both or neither. Keys are
# never generated or stored here. Previews never receive either, so a preview never offers to replace itself.
lunlet_update_feed=${LUNLET_UPDATE_FEED_URL:-}
lunlet_update_key=${LUNLET_UPDATE_PUBLIC_KEY:-}
if [ "$lunlet_preview" = true ]; then
    if [ -n "$lunlet_update_feed$lunlet_update_key" ]; then
        printf '%s\n' 'Preview builds never check for updates; ignoring LUNLET_UPDATE_FEED_URL and LUNLET_UPDATE_PUBLIC_KEY.' >&2
    fi
    lunlet_update_feed=
    lunlet_update_key=
elif [ -z "$lunlet_update_feed" ] && [ -z "$lunlet_update_key" ]; then
    printf '%s\n' 'No update feed is configured; this build will not check for updates.' >&2
elif [ -z "$lunlet_update_feed" ] || [ -z "$lunlet_update_key" ]; then
    printf '%s\n' 'Set both LUNLET_UPDATE_FEED_URL and LUNLET_UPDATE_PUBLIC_KEY, or neither.' >&2
    exit 2
elif ! printf '%s' "$lunlet_update_feed" | /usr/bin/grep -Eqx 'https://[^/[:space:]"]+(/[^[:space:]"]*)?'; then
    printf '%s\n' 'LUNLET_UPDATE_FEED_URL must be an https URL.' >&2
    exit 2
elif ! printf '%s' "$lunlet_update_key" | /usr/bin/grep -Eqx '[A-Za-z0-9+/]{43}='; then
    printf '%s\n' 'LUNLET_UPDATE_PUBLIC_KEY must be the base64 public key that Sparkle generate_keys prints.' >&2
    exit 2
fi
lunlet_source_revision=$(git rev-parse HEAD)
lunlet_source_dirty=false
if [ -n "$(git status --porcelain)" ]; then
    lunlet_source_dirty=true
fi
if [ "$lunlet_preview" = false ] && [ "$lunlet_source_dirty" = true ]; then
    printf '%s\n' 'A normal distribution build requires a clean source checkout.' >&2
    exit 2
fi
. scripts/swift-common.sh
lunlet_swift build --product Lunlet --configuration "$lunlet_configuration"
lunlet_binary_directory=$(lunlet_swift build --show-bin-path --configuration "$lunlet_configuration")
lunlet_bundle=${LUNLET_APP_OUTPUT:-"$PWD/.tmp/Lunlet.app"}
mkdir -p "$lunlet_bundle/Contents/MacOS"
rm -rf "$lunlet_bundle/Contents/Resources"
rm -rf "$lunlet_bundle/Contents/Helpers"
rm -rf "$lunlet_bundle/Contents/Frameworks"
mkdir -p "$lunlet_bundle/Contents/Resources/third-party"
cp "$lunlet_binary_directory/Lunlet" "$lunlet_bundle/Contents/MacOS/Lunlet"
# Sparkle loads from the bundle only: drop search paths into this checkout's build directories and add the bundle's.
mkdir -p "$lunlet_bundle/Contents/Frameworks"
/usr/bin/ditto "$lunlet_binary_directory/Sparkle.framework" "$lunlet_bundle/Contents/Frameworks/Sparkle.framework"
/usr/bin/otool -l "$lunlet_bundle/Contents/MacOS/Lunlet" | /usr/bin/sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' |
    while IFS= read -r lunlet_rpath; do
        case "$lunlet_rpath" in
            "$PWD"/*) /usr/bin/install_name_tool -delete_rpath "$lunlet_rpath" "$lunlet_bundle/Contents/MacOS/Lunlet" ;;
        esac
    done
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$lunlet_bundle/Contents/MacOS/Lunlet"
cp Resources/Info.plist "$lunlet_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LunletDevelopmentPreview bool $lunlet_preview" "$lunlet_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LunletSourceRevision string $lunlet_source_revision" "$lunlet_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LunletSourceDirty bool $lunlet_source_dirty" "$lunlet_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LunletBuildConfiguration string $lunlet_configuration" "$lunlet_bundle/Contents/Info.plist"
if [ -n "$lunlet_update_feed" ]; then
    /usr/bin/plutil -insert SUFeedURL -string "$lunlet_update_feed" "$lunlet_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert SUPublicEDKey -string "$lunlet_update_key" "$lunlet_bundle/Contents/Info.plist"
fi
cp Resources/Lunlet.icns "$lunlet_bundle/Contents/Resources/"
cp Resources/third-party/swift-protobuf-license.txt "$lunlet_bundle/Contents/Resources/third-party/"
cp Resources/third-party/sparkle-license.txt "$lunlet_bundle/Contents/Resources/third-party/"
if [ -f NOTICE.md ]; then
    cp NOTICE.md "$lunlet_bundle/Contents/Resources/third-party/NOTICE.md"
fi
if [ -f LICENSE ]; then
    cp LICENSE "$lunlet_bundle/Contents/Resources/third-party/lunlet-license.txt"
fi
cp -R "$lunlet_binary_directory/SwiftProtobuf_SwiftProtobuf.bundle" "$lunlet_bundle/Contents/Resources/"
if [ "$lunlet_preview" = false ]; then
    if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$lunlet_source_revision" ]; then
        printf '%s\n' 'Source changed during the build. Rebuild from the matching clean tag.' >&2
        exit 2
    fi
fi
# Sign inside out with one identity (scripts/sign-app.sh). Only a certificate-signed build gets the hardened runtime:
# an ad hoc signature has no team identifier, and the runtime's library validation would refuse the embedded
# Sparkle framework at launch.
if [ "$lunlet_preview" = true ]; then lunlet_sign_mode=--preview
elif [ "$lunlet_signing_identity" = - ]; then lunlet_sign_mode=--unsigned
else lunlet_sign_mode=--signed
fi
scripts/sign-app.sh "$lunlet_sign_mode" "$lunlet_signing_identity" "$lunlet_bundle"
printf '%s\n' "$lunlet_bundle"
