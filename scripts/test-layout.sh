#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp/}office-tabs-layout.XXXXXX")"
cleanup() {
    swift -e 'import Foundation; try? FileManager.default.removeItem(atPath: CommandLine.arguments[1])' "$TEST_BUILD_DIR"
}
trap cleanup EXIT

# 只运行布局、身份匹配和拖动预测的纯数据用例，Command Line Tools 即可运行，不枚举真实窗口。
swiftc -swift-version 5 -parse-as-library \
    "$PROJECT_ROOT/Sources/OfficeTabs/WindowPlacement.swift" \
    "$PROJECT_ROOT/Tests/WindowPlacementTests.swift" \
    -o "$TEST_BUILD_DIR/layout-tests"
"$TEST_BUILD_DIR/layout-tests"

swiftc -swift-version 5 -parse-as-library \
    "$PROJECT_ROOT/Sources/OfficeTabs/WindowServerGeometry.swift" \
    "$PROJECT_ROOT/Tests/WindowServerGeometryTests.swift" \
    -o "$TEST_BUILD_DIR/window-server-tests"
"$TEST_BUILD_DIR/window-server-tests"

swiftc -swift-version 5 -parse-as-library \
    "$PROJECT_ROOT/Sources/OfficeTabs/CursorDragModel.swift" \
    "$PROJECT_ROOT/Tests/CursorDragModelTests.swift" \
    -o "$TEST_BUILD_DIR/cursor-drag-tests"
"$TEST_BUILD_DIR/cursor-drag-tests"
