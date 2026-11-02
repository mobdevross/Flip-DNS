#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$project_dir/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift_args=(--disable-sandbox --cache-path "$project_dir/.build/cache"
    --config-path "$project_dir/.build/configuration" --security-path "$project_dir/.build/security"
    -c release -debug-info-format none)
swift build "${swift_args[@]}"
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
app_dir="$project_dir/dist/Flip.app"

# Rebuild in place without deleting an existing bundle or unrelated artifacts.
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/DNSSwitch" "$app_dir/Contents/MacOS/DNSSwitch"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
