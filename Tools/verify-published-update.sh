#!/bin/zsh
# Copyright 2026 Myf-ricey
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export FANGE_LIVE_UPDATE_CHECK=1
export FANGE_LIVE_UPDATE_DOWNLOAD=1
export FANGE_EXPECTED_UPDATE_VERSION="$(tr -d '\n\r' < "$repo_dir/VERSION")"
if [[ -n "${1:-}" ]]; then
  export FANGE_PREVIOUS_UPDATE_VERSION="$1"
fi
exec "$repo_dir/test-updates.sh"
