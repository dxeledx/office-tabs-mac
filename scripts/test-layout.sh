#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp/}office-tabs-layout.XXXXXX")"
cleanup() {
    swift -e 'import Foundation; try? FileManager.default.removeItem(atPath: CommandLine.arguments[1])' "$TEST_BUILD_DIR"
}
trap cleanup EXIT

# 仅编译纯布局代码，Command Line Tools 即可运行，也不会启动标签栏或访问 Office。
swiftc -swift-version 5 -parse-as-library \
    "$PROJECT_ROOT/Sources/OfficeTabs/WindowPlacement.swift" \
    "$PROJECT_ROOT/Tests/WindowPlacementTests.swift" \
    -o "$TEST_BUILD_DIR/layout-tests"
"$TEST_BUILD_DIR/layout-tests"
