#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
interaction_provider="${1:-openai}"
coding_provider="${2:-anthropic}"
env_file="${VIBETALKER_ENV_FILE:-$repo_root/.env}"

environment_key_for_provider() {
    case "$1" in
        anthropic) echo "ANTHROPIC_API_KEY" ;;
        openai) echo "OPENAI_API_KEY" ;;
        openrouter) echo "OPENROUTER_API_KEY" ;;
        openai-compatible|responses-compatible) echo "OMLX_API_KEY" ;;
        *)
            echo "error: provider must be anthropic, openai, openrouter, openai-compatible, or responses-compatible" >&2
            return 2
            ;;
    esac
}

credential_for_key() {
    local requested_key="$1"
    /usr/bin/awk -F= -v requested="$requested_key" '
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
}

interaction_environment_key="$(environment_key_for_provider "$interaction_provider")"
coding_environment_key="$(environment_key_for_provider "$coding_provider")"
interaction_credential="$(credential_for_key "$interaction_environment_key")"
coding_credential="$(credential_for_key "$coding_environment_key")"
if [[ -z "$interaction_credential" ]]; then
    echo "error: $interaction_environment_key is missing or empty in $env_file" >&2
    exit 1
fi
if [[ -z "$coding_credential" ]]; then
    echo "error: $coding_environment_key is missing or empty in $env_file" >&2
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
export "${interaction_environment_key}=${interaction_credential}"
export "${coding_environment_key}=${coding_credential}"
unset interaction_credential coding_credential
exec "$app_binary"
