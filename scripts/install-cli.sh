#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="${1:-}"
if [ -z "$app_dir" ]; then
    if [ -d /Applications/Flip.app ]; then
        app_dir=/Applications/Flip.app
    elif [ -d "$HOME/Applications/Flip.app" ]; then
        app_dir="$HOME/Applications/Flip.app"
    else
        app_dir="$project_dir/dist/Flip.app"
    fi
fi

if [ ! -x "$app_dir/Contents/MacOS/DNSSwitch" ]; then
    printf 'Build Flip first, or pass the path to Flip.app as the first argument.\n' >&2
    exit 1
fi
control_version="$(/usr/bin/plutil -extract FlipControlProtocolVersion raw -o - "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
if [ "$control_version" != "1" ]; then
    printf 'This app build does not include the current CLI. Rebuild Flip or pass the path to an updated Flip.app.\n' >&2
    exit 1
fi
app_dir="$(cd -- "$app_dir" && pwd -P)"
binary="$app_dir/Contents/MacOS/DNSSwitch"
bin_dir="${2:-$HOME/.local/bin}"
mkdir -p "$bin_dir"
bin_dir="$(cd -- "$bin_dir" && pwd -P)"
cli_path="$bin_dir/flip"

if [ -e "$cli_path" ] || [ -L "$cli_path" ]; then
    if [ ! -L "$cli_path" ] || [ "$(readlink "$cli_path")" != "$binary" ]; then
        printf 'Refusing to replace the existing file: %s\n' "$cli_path" >&2
        exit 1
    fi
else
    ln -s "$binary" "$cli_path"
fi
printf 'CLI ready: %s\nKeep Flip.app running and ensure %s is on PATH.\n' "$cli_path" "$bin_dir"
