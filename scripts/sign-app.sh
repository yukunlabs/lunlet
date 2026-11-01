#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-27, AC-27.03, AC-27.05; US-35, AC-35.02.
# Signs an assembled Lunlet.app inside out with one identity: Sparkle's helpers as Sparkle documents for apps outside
# the sandbox, then every embedded framework, then the app.
#
# Usage: scripts/sign-app.sh --preview|--unsigned|--signed <identity> /absolute/Lunlet.app
#
# Only a certificate-signed build (--signed) gets the hardened runtime and a secure timestamp, which notarization
# needs. An ad hoc signature carries no team identifier, and the hardened runtime's library validation then refuses
# the app's own embedded frameworks at launch (dyld: "different Team IDs"); the first unsigned candidate crashed that
# way on 2026-11-01. So --unsigned (the unsigned preview release) and --preview sign without the runtime.
set -eu

lunlet_mode=${1:-}
lunlet_identity=${2:-}
lunlet_bundle=${3:-}
case "$lunlet_mode" in --preview|--unsigned|--signed) ;; *) lunlet_mode= ;; esac
if [ -z "$lunlet_mode" ] || [ -z "$lunlet_identity" ] || [ "$#" -ne 3 ] || [ ! -d "$lunlet_bundle/Contents" ]; then
    printf '%s\n' 'Usage: scripts/sign-app.sh --preview|--unsigned|--signed <identity> /absolute/Lunlet.app' >&2
    exit 2
fi
case "$lunlet_bundle" in /*) ;; *) printf '%s\n' 'The application path must be absolute.' >&2; exit 2 ;; esac
if [ "$lunlet_mode" = --unsigned ] && [ "$lunlet_identity" != - ]; then
    printf '%s\n' 'An unsigned preview release is signed ad hoc: pass - as the identity.' >&2; exit 2
fi
if [ "$lunlet_mode" = --signed ] && [ "$lunlet_identity" = - ]; then
    printf '%s\n' 'A signed build needs a certificate identity.' >&2; exit 2
fi

lunlet_sign() {
    if [ "$lunlet_mode" = --signed ]; then
        /usr/bin/codesign --force --options runtime --timestamp --sign "$lunlet_identity" "$@"
    else
        /usr/bin/codesign --force --sign "$lunlet_identity" "$@"
    fi
}

lunlet_sparkle="$lunlet_bundle/Contents/Frameworks/Sparkle.framework"
if [ -d "$lunlet_sparkle" ]; then
    lunlet_sign "$lunlet_sparkle/Versions/B/XPCServices/Installer.xpc"
    lunlet_sign --preserve-metadata=entitlements "$lunlet_sparkle/Versions/B/XPCServices/Downloader.xpc"
    lunlet_sign "$lunlet_sparkle/Versions/B/Autoupdate"
    lunlet_sign "$lunlet_sparkle/Versions/B/Updater.app"
fi
for lunlet_framework in "$lunlet_bundle"/Contents/Frameworks/*.framework; do
    [ -d "$lunlet_framework" ] && lunlet_sign "$lunlet_framework"
done
lunlet_sign "$lunlet_bundle"
/usr/bin/codesign --verify --deep --strict "$lunlet_bundle"
