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
python_root="$runtime_root/Python"
shared_python="$python_root/bin/python3.12"

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
python_source_root="$("$python_command" -c 'import sys; print(sys.prefix)')"
if [[ "$python_source_root" != /* ]] || [[ ! -x "$python_source_root/bin/python3.12" ]]; then
    echo "error: Could not resolve the relocatable Python 3.12.11 runtime."
    exit 1
fi

install_target_packages() {
    local destination="$1"
    shift
    if [[ "$destination" != "$runtime_root/"* ]] || [[ "$destination" == "$runtime_root" ]]; then
        echo "error: Refusing to replace package target outside the runtime root."
        exit 1
    fi
    rm -rf "$destination"
    mkdir -p "$destination"
    if command -v "$uv_command" >/dev/null; then
        "$uv_command" pip install \
            --python "$shared_python" \
            --target "$destination" \
            "$@"
    else
        "$python_command" -m pip install --target "$destination" "$@"
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

/usr/bin/rsync -a --delete "$python_source_root/" "$python_root/"
for obsolete_environment in "$mlx_checkout/.venv" "$rag_checkout/.venv"; do
    if [[ -d "$obsolete_environment" ]] &&
       [[ "$obsolete_environment" == "$runtime_root/"* ]]; then
        rm -rf "$obsolete_environment"
    fi
done

install_target_packages "$mlx_checkout/site-packages" \
    -r "$repo_root/Dependencies/moshi-mlx-requirements.lock" \
    "$mlx_checkout/moshi_mlx"

install_target_packages "$rag_checkout/site-packages" \
    --no-deps \
    "$rag_checkout/moshi"
install_target_packages "$rag_checkout/dependencies" \
    -r "$repo_root/Dependencies/moshi-rag-conditioner-requirements.lock"
/usr/bin/rsync -a "$rag_checkout/dependencies/" "$rag_checkout/site-packages/"
rm -rf "$rag_checkout/dependencies"

HF_HOME="$runtime_root/HuggingFace" \
    PYTHONPATH="$rag_checkout/site-packages" \
    "$shared_python" \
    "$repo_root/scripts/download-voice-models.py" \
    "$runtime_root" \
    "$repo_root/Dependencies/moshi-rag-pytorch-config.json"

mkdir -p "$model_root"
if [[ ! -f "$model_root/moshika-rag-mlx-bf16.safetensors" ]]; then
    PYTHONPATH="$rag_checkout/site-packages" \
        "$shared_python" \
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
    PYTHONPATH="$rag_checkout/site-packages" \
    "$shared_python" -c \
    "import torch; import moshi; assert torch.backends.mps.is_available()"
PYTHONPATH="$mlx_checkout/site-packages" \
    "$shared_python" -c "import mlx.core; import moshi_mlx"

marker="$runtime_root/.vibetalker-voice-runtime"
{
    echo "moshi=$moshi_revision"
    echo "moshi-rag=$rag_revision"
    /usr/bin/shasum -a 256 \
        "$repo_root/Patches/moshi-mlx-rag-apple-silicon.patch" \
        "$repo_root/Patches/moshi-rag-apple-silicon-conditioner.patch"
} > "$marker"

echo "Built the VibeTalker voice runtime from pinned GitHub sources in $runtime_root"
