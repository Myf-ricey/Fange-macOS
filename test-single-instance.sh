#!/bin/zsh

# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d -t desktop-regions-instance-test)"
TEST_BIN="$TEST_DIR/instance-lock-probe"
LOCK_PATH="$TEST_DIR/active-instance.lock"
FIRST_OUTPUT="$TEST_DIR/first.txt"
SECOND_OUTPUT="$TEST_DIR/second.txt"
THIRD_OUTPUT="$TEST_DIR/third.txt"
FIRST_PID=""

cleanup() {
  if [[ -n "$FIRST_PID" ]] && kill -0 "$FIRST_PID" 2>/dev/null; then
    kill "$FIRST_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

swiftc \
  -framework Cocoa \
  "$ROOT_DIR/Sources/DesktopRegions/AppInstanceCoordinator.swift" \
  "$ROOT_DIR/Tests/AppInstanceLockProbe.swift" \
  -o "$TEST_BIN"

"$TEST_BIN" "$LOCK_PATH" 800 > "$FIRST_OUTPUT" &
FIRST_PID=$!

for _ in {1..40}; do
  [[ -s "$FIRST_OUTPUT" ]] && break
  sleep 0.02
done
grep -qx "ACQUIRED" "$FIRST_OUTPUT"

set +e
"$TEST_BIN" "$LOCK_PATH" 0 > "$SECOND_OUTPUT"
SECOND_STATUS=$?
set -e
[[ "$SECOND_STATUS" -eq 23 ]]
grep -qx "BUSY" "$SECOND_OUTPUT"

wait "$FIRST_PID"
FIRST_PID=""

"$TEST_BIN" "$LOCK_PATH" 0 > "$THIRD_OUTPUT"
grep -qx "ACQUIRED" "$THIRD_OUTPUT"

echo "single instance process lock: PASS"
