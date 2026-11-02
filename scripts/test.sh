#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$project_dir/.build/swift-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift test --disable-sandbox --cache-path "$project_dir/.build/cache" \
    --scratch-path "$project_dir/.build/swift" \
    --config-path "$project_dir/.build/configuration" --security-path "$project_dir/.build/security" "$@"
