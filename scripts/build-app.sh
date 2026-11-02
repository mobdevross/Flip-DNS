#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$project_dir/.build/swift-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift_args=(--disable-sandbox --cache-path "$project_dir/.build/cache"
    --config-path "$project_dir/.build/configuration" --security-path "$project_dir/.build/security"
    --scratch-path "$project_dir/.build/swift"
    -c release -debug-info-format none)
swift build "${swift_args[@]}"
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.flip-build.XXXXXX")"
app_dir="$staging_dir/Flip.app"

# Sign a complete new bundle before replacing the previous build. Renaming the
# old bundle preserves its executable inode if that version is still running.
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/DNSSwitch" "$app_dir/Contents/MacOS/DNSSwitch"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
destination="$project_dir/dist/Flip.app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    mkdir -p "$project_dir/dist/previous-builds"
    backup_dir="$(mktemp -d "$project_dir/dist/previous-builds/flip.XXXXXX")"
    mv "$destination" "$backup_dir/Flip.app"
fi
mv "$app_dir" "$destination"
rmdir "$staging_dir"
printf 'Built: %s\n' "$destination"
