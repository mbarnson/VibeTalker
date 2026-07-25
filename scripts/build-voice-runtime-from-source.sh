#!/bin/bash
set -euo pipefail

moshi_repository=https://github.com/kyutai-labs/moshi.git
moshi_revision=e6a55d2722a65870ef52a6c9f6ecfc0e90f38362
rag_repository=https://github.com/kyutai-labs/moshi-rag.git
rag_revision=8c6dfc101b7871baa428424bcdc583b74fb561d9

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"
default_runtime_root="$repo_root/Vendor/voice-runtime"
runtime_root="${1:-$default_runtime_root}"
python_command="${PYTHON_COMMAND:-python3.12}"
uv_command="${UV_COMMAND:-uv}"
mlx_checkout="$runtime_root/moshi-mlx"
rag_checkout="$runtime_root/moshi-rag"
model_root="$runtime_root/Models"

if [[ "$runtime_root" != /* ]] || [[ "$runtime_root" == "/" ]]; then
    echo "error: Runtime root must be an absolute, non-root path."
    exit 1
fi
if ! command -v "$python_command" >/dev/null; then
    echo "error: Python 3.12 is required (override with PYTHON_COMMAND)."
    exit 1
fi
python_version="$("$python_command" -c 'import platform; print(platform.python_version())')"
if [[ "$python_version" != "3.12.11" ]]; then
    echo "error: Expected Python 3.12.11, found $python_version."
    exit 1
fi

create_environment() {
    local destination="$1"
    if command -v "$uv_command" >/dev/null; then
        "$uv_command" venv --clear --python "$python_command" "$destination"
    else
        "$python_command" -m venv --clear "$destination"
        "$destination/bin/python" -m pip install --upgrade pip
    fi
}

install_packages() {
    local environment="$1"
    shift
    if command -v "$uv_command" >/dev/null; then
        "$uv_command" pip install --python "$environment/bin/python" "$@"
    else
        "$environment/bin/python" -m pip install "$@"
    fi
}

prepare_checkout() {
    local repository="$1"
    local revision="$2"
    local checkout="$3"
    local patch="$4"

    if [[ ! -d "$checkout/.git" ]]; then
        mkdir -p "$(dirname "$checkout")"
        git clone --filter=blob:none "$repository" "$checkout"
    fi
    git -C "$checkout" fetch origin "$revision"
    if [[ "$(git -C "$checkout" rev-parse HEAD)" != "$revision" ]]; then
        if ! git -C "$checkout" diff --quiet ||
           ! git -C "$checkout" diff --cached --quiet; then
            echo "error: Refusing to replace modified checkout: $checkout"
            exit 1
        fi
        git -C "$checkout" checkout --detach "$revision"
    fi

    if git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
        return
    fi
    if ! git -C "$checkout" diff --quiet ||
       ! git -C "$checkout" diff --cached --quiet; then
        echo "error: Checkout has changes other than the tracked VibeTalker patch: $checkout"
        exit 1
    fi
    git -C "$checkout" apply --check "$patch"
    git -C "$checkout" apply "$patch"
}

prepare_checkout \
    "$moshi_repository" \
    "$moshi_revision" \
    "$mlx_checkout" \
    "$repo_root/Patches/moshi-mlx-rag-apple-silicon.patch"
prepare_checkout \
    "$rag_repository" \
    "$rag_revision" \
    "$rag_checkout" \
    "$repo_root/Patches/moshi-rag-apple-silicon-conditioner.patch"

create_environment "$mlx_checkout/.venv"
install_packages "$mlx_checkout/.venv" \
    -r "$repo_root/Dependencies/moshi-mlx-requirements.lock" \
    "$mlx_checkout/moshi_mlx"

create_environment "$rag_checkout/.venv"
install_packages "$rag_checkout/.venv" --no-deps "$rag_checkout/moshi"
install_packages "$rag_checkout/.venv" \
    -r "$repo_root/Dependencies/moshi-rag-conditioner-requirements.lock"

HF_HOME="$runtime_root/HuggingFace" \
    "$rag_checkout/.venv/bin/python" \
    "$repo_root/scripts/download-voice-models.py" \
    "$runtime_root" \
    "$repo_root/Dependencies/moshi-rag-pytorch-config.json"

mkdir -p "$model_root"
if [[ ! -f "$model_root/moshika-rag-mlx-bf16.safetensors" ]]; then
    "$rag_checkout/.venv/bin/python" \
        "$rag_checkout/scripts/import_mlx.py" \
        "$model_root/moshika-rag-pytorch-bf16.safetensors" \
        "$model_root/moshika-rag-mlx-bf16.safetensors" \
        --silent
fi

/bin/cp "$repo_root/Dependencies/moshi-rag-mlx-config.json" \
    "$runtime_root/moshi-rag-mlx-config.json"

HF_HOME="$runtime_root/HuggingFace" \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_OFFLINE=1 \
    "$rag_checkout/.venv/bin/python" -c \
    "import torch; import moshi; assert torch.backends.mps.is_available()"
"$mlx_checkout/.venv/bin/python" -c "import mlx.core; import moshi_mlx"

marker="$runtime_root/.vibetalker-voice-runtime"
{
    echo "moshi=$moshi_revision"
    echo "moshi-rag=$rag_revision"
    /usr/bin/shasum -a 256 \
        "$repo_root/Patches/moshi-mlx-rag-apple-silicon.patch" \
        "$repo_root/Patches/moshi-rag-apple-silicon-conditioner.patch"
} > "$marker"

echo "Built the VibeTalker voice runtime from pinned GitHub sources in $runtime_root"
