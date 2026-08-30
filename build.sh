#!/bin/zsh

# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/DesktopRegions.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

swiftc \
  -O \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework Cocoa \
  "$ROOT_DIR"/Sources/DesktopRegions/*.swift \
  -o "$CONTENTS_DIR/MacOS/DesktopRegions"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$CONTENTS_DIR/Resources/PrivacyInfo.xcprivacy"
chmod +x "$CONTENTS_DIR/MacOS/DesktopRegions"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
