#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: scripts/bootstrap-from-source.sh"
    echo "Build pinned pi and Moshi runtimes, then build and sign VibeTalker."
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "error: bootstrap-from-source.sh accepts no arguments." >&2
    exit 2
fi

required_commands=(git npm cargo python3.12 xcodebuild)
for command in "${required_commands[@]}"; do
    if ! command -v "$command" >/dev/null; then
        echo "error: Missing required command: $command" >&2
        exit 1
    fi
done
if [[ ! -x /opt/homebrew/bin/brew ]]; then
    echo "error: Homebrew is required at /opt/homebrew/bin/brew." >&2
    exit 1
fi

echo "Building pi from its pinned GitHub revision..."
"$script_dir/build-pi-from-source.sh" "$repo_root/Vendor/pi-mono"

echo "Building Moshi-RAG from pinned GitHub revisions..."
"$script_dir/build-voice-runtime-from-source.sh" \
    "$repo_root/Vendor/voice-runtime"

echo "Building and signing VibeTalker with Xcode..."
xcodebuild \
    -project "$repo_root/VibeTalker.xcodeproj" \
    -scheme VibeTalker \
    -destination "platform=macOS" \
    build

build_settings="$(
    xcodebuild \
        -project "$repo_root/VibeTalker.xcodeproj" \
        -scheme VibeTalker \
        -destination "platform=macOS" \
        -showBuildSettings
)"
target_build_dir="$(
    /usr/bin/awk -F' = ' \
        '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' \
        <<<"$build_settings"
)"
wrapper_name="$(
    /usr/bin/awk -F' = ' \
        '/^[[:space:]]*WRAPPER_NAME = / { print $2; exit }' \
        <<<"$build_settings"
)"

echo "VibeTalker is ready at $target_build_dir/$wrapper_name"
echo "Launch it with: scripts/run-vibetalker-dev.sh"
