#!/bin/zsh
# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BIN="$(mktemp -t desktop-regions-folder-test)"
trap 'rm -f "$TEST_BIN"' EXIT
swiftc -framework Cocoa \
  "$ROOT_DIR/Sources/DesktopRegions/Models.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionFileSorting.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/FolderMapping.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/DesktopItemVisibility.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionFilesView.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionLayout.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionView.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionWindowController.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/InteractionPolicy.swift" \
  "$ROOT_DIR/Tests/FolderFeaturesTests.swift" \
  -o "$TEST_BIN"
"$TEST_BIN"
