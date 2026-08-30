#!/bin/zsh

# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BIN="$(mktemp -t desktop-regions-drag-test)"
trap 'rm -f "$TEST_BIN"' EXIT

swiftc \
  -framework Cocoa \
  "$ROOT_DIR/Sources/DesktopRegions/Models.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/InteractionPolicy.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionLayout.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionView.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/RegionWindowController.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/StatusBarIcon.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/FinderDesktopMonitor.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/WorkspaceUndoHistory.swift" \
  "$ROOT_DIR/Sources/DesktopRegions/DesktopArranger.swift" \
  "$ROOT_DIR/Tests/InteractionPolicyTests.swift" \
  -o "$TEST_BIN"

"$TEST_BIN"
