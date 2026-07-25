#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
provider="${1:-anthropic}"
env_file="${VIBETALKER_ENV_FILE:-$repo_root/.env}"

case "$provider" in
    anthropic) environment_key="ANTHROPIC_API_KEY" ;;
    openai) environment_key="OPENAI_API_KEY" ;;
    openrouter) environment_key="OPENROUTER_API_KEY" ;;
    openai-compatible|responses-compatible) environment_key="OMLX_API_KEY" ;;
    *)
        echo "error: provider must be anthropic, openai, openrouter, openai-compatible, or responses-compatible" >&2
        exit 2
        ;;
esac

credential="$(
    /usr/bin/awk -F= -v requested="$environment_key" '
        $1 == requested {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            first = substr(value, 1, 1)
            last = substr(value, length(value), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$env_file"
)"
if [[ -z "$credential" ]]; then
    echo "error: $environment_key is missing or empty in $env_file" >&2
    exit 1
fi

build_settings="$(
    xcodebuild \
        -project "$repo_root/VibeTalker.xcodeproj" \
        -scheme VibeTalker \
        -destination "platform=macOS" \
        -showBuildSettings
)"
target_build_dir="$(
    /usr/bin/awk -F' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' \
        <<<"$build_settings"
)"
wrapper_name="$(
    /usr/bin/awk -F' = ' '/^[[:space:]]*WRAPPER_NAME = / { print $2; exit }' \
        <<<"$build_settings"
)"
app_binary="$target_build_dir/$wrapper_name/Contents/MacOS/VibeTalker"
if [[ ! -x "$app_binary" ]]; then
    echo "error: build VibeTalker first; missing $app_binary" >&2
    exit 1
fi

unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY OMLX_API_KEY
export "${environment_key}=${credential}"
unset credential
exec "$app_binary"
