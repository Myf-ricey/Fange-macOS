#!/bin/zsh
# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '\n\r' < "$repo_dir/VERSION")"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_dir/Resources/Info.plist")"
[[ "$version" == "$plist_version" ]] || { echo 'VERSION and Info.plist disagree' >&2; exit 1; }
brand_dir="${1:-}"
keka_binary="/Applications/Keka.app/Contents/MacOS/Keka"
[[ -x "$keka_binary" ]] || { echo "Keka is required at $keka_binary" >&2; exit 1; }
if [[ -n "$brand_dir" ]]; then
  brand_dir="$(cd "$brand_dir" && pwd)"
  [[ -f "$brand_dir/FangeAppIcon.icns" && -f "$brand_dir/FangeTitle.png" ]] || { echo 'Brand images missing' >&2; exit 1; }
fi
release_dir="$repo_dir/release/v$version"
[[ ! -e "$release_dir" ]] || { echo "Output already exists: $release_dir" >&2; exit 2; }

# Keka's sandbox can access this staging location without interactive grants.
scratch_parent="$HOME/Library/Containers/com.aone.keka/Data/tmp"
mkdir -p "$scratch_parent"
build_dir="$(mktemp -d "$scratch_parent/fange-release.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
package_dir="$build_dir/package"
app_dir="$package_dir/饭格.app"
contents_dir="$app_dir/Contents"
archive_name="Fange-v$version-macOS-universal.zip"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
for arch in arm64 x86_64; do
  swiftc -O -target "${arch}-apple-macosx13.0" -framework Cocoa \
    "$repo_dir"/Sources/DesktopRegions/*.swift -o "$build_dir/DesktopRegions-$arch"
done
lipo -create "$build_dir/DesktopRegions-arm64" "$build_dir/DesktopRegions-x86_64" \
  -output "$contents_dir/MacOS/DesktopRegions"
cp "$repo_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$repo_dir/Resources/PrivacyInfo.xcprivacy" "$contents_dir/Resources/"
if [[ -n "$brand_dir" ]]; then
  cp "$brand_dir/FangeAppIcon.icns" "$brand_dir/FangeTitle.png" "$contents_dir/Resources/"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string FangeAppIcon.icns' "$contents_dir/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :NSHumanReadableCopyright Copyright © 2026 Myf-ricey. Code: Apache-2.0. Brand assets: all rights reserved.' "$contents_dir/Info.plist"
fi
for document in LICENSE NOTICE BRAND_ASSETS.md; do
  cp "$repo_dir/$document" "$contents_dir/Resources/"
  cp "$repo_dir/$document" "$package_dir/"
done
chmod +x "$contents_dir/MacOS/DesktopRegions"
# Ad-hoc only: Developer ID signing and notarization remain a separate step.
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
lipo "$contents_dir/MacOS/DesktopRegions" -verify_arch arm64 x86_64
(
  cd "$package_dir"
  "$keka_binary" --ignore-file-access --cli 7z a -tzip -mx=9 \
    "$build_dir/$archive_name" 饭格.app LICENSE NOTICE BRAND_ASSETS.md
)
"$keka_binary" --ignore-file-access --cli 7z t "$build_dir/$archive_name"
mkdir -p "$release_dir"
cp "$build_dir/$archive_name" "$release_dir/"
(
  cd "$release_dir"
  shasum -a 256 "$archive_name" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
echo "Release artifacts: $release_dir"
echo 'Ad-hoc signed; not notarized.'
