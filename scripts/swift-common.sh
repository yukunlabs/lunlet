#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-10, AC-10.02, AC-10.04; US-11, AC-11.05.
# Keep compiler options identical between app builds and tests so alternating
# those commands does not invalidate the shared incremental build cache.
lunlet_developer_dir=$(xcode-select -p)
lunlet_testing_plugin="$lunlet_developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

lunlet_swift() {
    lunlet_swift_subcommand=$1
    shift
    set -- "$lunlet_swift_subcommand" --disable-keychain --disable-automatic-resolution "$@"
    if [ -f "$lunlet_testing_plugin" ]; then
        set -- "$@" -Xswiftc -load-plugin-library -Xswiftc "$lunlet_testing_plugin"
    fi
    command swift "$@"
}
