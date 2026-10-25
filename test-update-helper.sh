#!/bin/zsh
# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BIN="$(mktemp -t desktop-regions-installer-test)"
trap 'rm -f "$TEST_BIN"' EXIT
swiftc -framework Cocoa \
  "$ROOT_DIR/Sources/DesktopRegions/UpdateRelease.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/UpdateInstaller.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/AppInstanceCoordinator.swift" \
  "$ROOT_DIR/Tests/UpdateHelperTests.swift" \
  -o "$TEST_BIN"
"$TEST_BIN" "$ROOT_DIR/DesktopRegions.app/Contents/MacOS/DesktopRegions"
