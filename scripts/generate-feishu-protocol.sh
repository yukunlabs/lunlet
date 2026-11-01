#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-01, AC-01.02; US-10, AC-10.02, AC-10.04.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
swift package resolve
lunlet_dependency="$PWD/.build/checkouts/swift-protobuf"
lunlet_expected_revision=3d537cb81aef272a03cb3be815439e9bf0eb3bd3
if [ "$(git -C "$lunlet_dependency" rev-parse HEAD)" != "$lunlet_expected_revision" ]; then
    printf '%s\n' 'Protocol generation requires the reviewed SwiftProtobuf revision.' >&2
    exit 1
fi
git -C "$lunlet_dependency" diff --exit-code --quiet
git -C "$lunlet_dependency" diff --cached --exit-code --quiet
lunlet_codegen_directory="$PWD/.tmp/protobuf-codegen"
swift build --package-path "$lunlet_dependency" --scratch-path "$lunlet_codegen_directory" --product protoc --jobs 4
swift build --package-path "$lunlet_dependency" --scratch-path "$lunlet_codegen_directory" --product protoc-gen-swift --jobs 4
lunlet_tool_directory=$(swift build --package-path "$lunlet_dependency" --scratch-path "$lunlet_codegen_directory" --show-bin-path)
mkdir -p Sources/LunletFeishu/Generated
"$lunlet_tool_directory/protoc" -I Sources/LunletFeishu \
    --plugin="protoc-gen-swift=$lunlet_tool_directory/protoc-gen-swift" \
    --swift_out=Sources/LunletFeishu/Generated \
    --swift_opt=Visibility=Internal --swift_opt=FileNaming=PathToUnderscores \
    Protocol/feishu_frame.proto
