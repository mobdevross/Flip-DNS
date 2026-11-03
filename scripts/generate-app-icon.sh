#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v rsvg-convert >/dev/null 2>&1; then
    printf 'Icon regeneration needs rsvg-convert (librsvg). Normal app builds use the committed AppIcon.icns.\n' >&2
    exit 1
fi

mkdir -p "$project_dir/.build"
icon_work="$(mktemp -d "$project_dir/.build/app-icon.XXXXXX")"
icon_set="$icon_work/AppIcon.iconset"
mkdir -p "$icon_set"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" "$project_dir/Resources/AppIcon.svg" \
        -o "$icon_set/icon_${size}x${size}.png"
    retina_size=$((size * 2))
    rsvg-convert -w "$retina_size" -h "$retina_size" "$project_dir/Resources/AppIcon.svg" \
        -o "$icon_set/icon_${size}x${size}@2x.png"
done
swift -module-cache-path "$project_dir/.build/swift-module-cache" \
    "$project_dir/scripts/pack-app-icon.swift" "$icon_set" "$project_dir/Resources/AppIcon.icns"
printf 'Generated: %s\nPreview sizes: %s\n' "$project_dir/Resources/AppIcon.icns" "$icon_set"
