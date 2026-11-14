#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-10, AC-10.02, AC-10.04; US-11, AC-11.05; US-33, AC-33.01; US-27, AC-27.02.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. scripts/swift-common.sh

# One entry for a developer's Mac and for the hosted validation, so a run means the same on both.
#   build        compiles the package and its tests
#   <module>     runs one module: core, storage, hook, codex, claude, feishu, messaging or desktop
#   all          runs every module in turn, each in its own process, so no module's tests wait behind another's
# Further arguments go to `swift test`, such as a focused `--filter`; without a module they select the tests alone.
# The desktop tests share the main thread, so they run one at a time rather than queue behind one another.
lunlet_modules="core storage hook codex claude feishu messaging desktop"

lunlet_module_tests() {
    case "$1" in
        core) echo LunletCoreTests ;;
        storage) echo LunletSecureStorageTests ;;
        hook) echo LunletHookTests ;;
        codex) echo LunletCodexTests ;;
        claude) echo LunletClaudeTests ;;
        feishu) echo LunletFeishuTests ;;
        messaging) echo LunletMessagingTests ;;
        desktop) echo LunletDesktopTests ;;
        *) return 1 ;;
    esac
}

lunlet_run_module() {
    lunlet_scope=$1
    shift
    set -- --filter "$(lunlet_module_tests "$lunlet_scope")" "$@"
    if [ "$lunlet_scope" = desktop ]; then set -- --no-parallel "$@"; fi
    lunlet_swift test --disable-xctest "$@"
}

case "${1:-}" in
    build)
        shift
        lunlet_swift build --build-tests "$@" ;;
    all)
        shift
        if [ "$#" -gt 0 ]; then
            lunlet_swift test --disable-xctest "$@"
        else
            for lunlet_scope in $lunlet_modules; do lunlet_run_module "$lunlet_scope"; done
        fi ;;
    core|storage|hook|codex|claude|feishu|messaging|desktop)
        lunlet_scope=$1
        shift
        lunlet_run_module "$lunlet_scope" "$@" ;;
    *)
        lunlet_swift test --disable-xctest "$@" ;;
esac
