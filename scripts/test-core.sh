#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-10, AC-10.02, AC-10.04; US-11, AC-11.05; US-33, AC-33.01.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. scripts/swift-common.sh

# A scope selects existing Swift test modules; no separate runner or cache.
lunlet_test_scope=
case "${1:-}" in
    core) lunlet_test_scope=LunletCoreTests; shift ;;
    codex) lunlet_test_scope=LunletCodexTests; shift ;;
    claude) lunlet_test_scope=LunletClaudeTests; shift ;;
    feishu) lunlet_test_scope=LunletFeishuTests; shift ;;
    messaging) lunlet_test_scope=LunletMessagingTests; shift ;;
    storage) lunlet_test_scope=LunletSecureStorageTests; shift ;;
    desktop) lunlet_test_scope=LunletDesktopTests; shift ;;
    all) shift ;;
esac
if [ -n "$lunlet_test_scope" ]; then
    set -- --filter "$lunlet_test_scope" "$@"
fi
lunlet_swift test --disable-xctest "$@"
