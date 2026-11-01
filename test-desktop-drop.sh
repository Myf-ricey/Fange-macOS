#!/bin/zsh
# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BIN="$(mktemp -t desktop-regions-drop-test)"
trap 'rm -f "$TEST_BIN"' EXIT
SOURCES=("$ROOT_DIR"/Sources/DesktopRegions/*.swift)
SOURCES=("${(@)SOURCES:#*/main.swift}")
swiftc -framework Cocoa "${SOURCES[@]}" "$ROOT_DIR/Tests/DesktopDropTests.swift" -o "$TEST_BIN"
"$TEST_BIN"
