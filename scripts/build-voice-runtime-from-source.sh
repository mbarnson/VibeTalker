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
cargo_command="${CARGO_COMMAND:-cargo}"
npm_command="${NPM_COMMAND:-npm}"
mlx_checkout="$runtime_root/moshi-mlx"
rag_checkout="$runtime_root/moshi-rag"
model_root="$runtime_root/Models"
python_root="$runtime_root/Python"
shared_python="$python_root/bin/python3.12"
stt_binary="$runtime_root/Bin/vibetalker-stt"
moshi_bf16_weight="$model_root/moshika-rag-mlx-bf16.safetensors"
moshi_q8_weight="$model_root/moshika-rag-mlx-q8.safetensors"
proactive_prompt="$runtime_root/proactive-completion-prompt.aiff"

if [[ "$runtime_root" != /* ]] || [[ "$runtime_root" == "/" ]]; then
    echo "error: Runtime root must be an absolute, non-root path."
    exit 1
fi
if ! command -v "$python_command" >/dev/null; then
    echo "error: Python 3.12 is required (override with PYTHON_COMMAND)."
    exit 1
fi
if ! command -v "$cargo_command" >/dev/null; then
    echo "error: Rust cargo is required (override with CARGO_COMMAND)."
    exit 1
fi
if ! command -v "$npm_command" >/dev/null; then
    echo "error: npm is required (override with NPM_COMMAND)."
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
    shift 3
    local patches=("$@")
    local patch
    local index

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

    for ((index=${#patches[@]} - 1; index >= 0; index--)); do
        patch="${patches[$index]}"
        if git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
            git -C "$checkout" apply --reverse "$patch"
        fi
    done
    if ! git -C "$checkout" diff --quiet ||
       ! git -C "$checkout" diff --cached --quiet; then
        echo "error: Checkout has changes other than the tracked VibeTalker patches: $checkout"
        exit 1
    fi
    for patch in "${patches[@]}"; do
        git -C "$checkout" apply --check "$patch"
        git -C "$checkout" apply "$patch"
    done
}

prepare_checkout \
    "$moshi_repository" \
    "$moshi_revision" \
    "$mlx_checkout" \
    "$repo_root/Patches/moshi-mlx-rag-apple-silicon.patch" \
    "$repo_root/Patches/moshi-mlx-app-sandbox-pipes.patch" \
    "$repo_root/Patches/moshi-mlx-streaming-stt.patch" \
    "$repo_root/Patches/moshi-mlx-nonblocking-log.patch" \
    "$repo_root/Patches/moshi-mlx-event-loop-fairness.patch" \
    "$repo_root/Patches/moshi-mlx-parent-termination.patch" \
    "$repo_root/Patches/moshi-mlx-proactive-completion.patch" \
    "$repo_root/Patches/moshi-mlx-retrieval-trigger.patch" \
    "$repo_root/Patches/moshi-mlx-long-session.patch"
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

(
    cd "$mlx_checkout/client"
    "$npm_command" ci
    "$npm_command" run build
)
if [[ ! -f "$mlx_checkout/client/dist/index.html" ]]; then
    echo "error: The pinned Moshi browser client did not build."
    exit 1
fi

install_target_packages "$rag_checkout/site-packages" \
    --no-deps \
    "$rag_checkout/moshi"
install_target_packages "$rag_checkout/dependencies" \
    -r "$repo_root/Dependencies/moshi-rag-conditioner-requirements.lock"
/usr/bin/rsync -a "$rag_checkout/dependencies/" "$rag_checkout/site-packages/"
rm -rf "$rag_checkout/dependencies"

CMAKE_POLICY_VERSION_MINIMUM=3.5 \
    PYO3_PYTHON="$shared_python" \
    "$cargo_command" build \
        --manifest-path "$rag_checkout/rust/Cargo.toml" \
        --profile release-no-debug \
        -p moshi-server \
        --features candle/accelerate,candle-nn/accelerate
mkdir -p "$(dirname "$stt_binary")"
/bin/cp \
    "$rag_checkout/rust/target/release-no-debug/moshi-server" \
    "$stt_binary"
python_library="$("$shared_python" -c \
    'import sysconfig; print(sysconfig.get_config_var("LDLIBRARY"))')"
linked_python="$(/usr/bin/otool -L "$stt_binary" | \
    /usr/bin/awk 'index($1, "libpython3.12.dylib") { print $1; exit }')"
if [[ -z "$linked_python" ]]; then
    echo "error: Source-built STT worker is not linked to the pinned Python 3.12 runtime."
    exit 1
fi
/usr/bin/install_name_tool \
    -change "$linked_python" "@rpath/$python_library" \
    "$stt_binary"
/usr/bin/install_name_tool \
    -add_rpath "@executable_path/../Python/lib" \
    "$stt_binary"
/bin/cp "$repo_root/Dependencies/moshi-stt.toml" \
    "$runtime_root/moshi-stt.toml"
/usr/bin/say -v Samantha -r 280 -o "$proactive_prompt" \
    "Moshi, give the update."

HF_HOME="$runtime_root/HuggingFace" \
    PYTHONPATH="$rag_checkout/site-packages" \
    "$shared_python" \
    "$repo_root/scripts/download-voice-models.py" \
    "$runtime_root" \
    "$repo_root/Dependencies/moshi-rag-pytorch-config.json"

mkdir -p "$model_root"
moshi_bf16_pending="${moshi_bf16_weight%.safetensors}.pending.safetensors"
PYTHONPATH="$rag_checkout/site-packages" \
    "$shared_python" \
    "$repo_root/scripts/convert-moshi-rag-candle-to-mlx.py" \
    "$model_root/moshika-rag-pytorch-bf16.safetensors" \
    "$moshi_bf16_pending"
/bin/mv "$moshi_bf16_pending" "$moshi_bf16_weight"

/bin/cp "$repo_root/Dependencies/moshi-rag-mlx-config.json" \
    "$runtime_root/moshi-rag-mlx-config.json"
moshi_q8_pending="${moshi_q8_weight%.safetensors}.pending.safetensors"
PYTHONPATH="$mlx_checkout/site-packages" \
    "$shared_python" \
    "$repo_root/scripts/quantize-moshi-mlx.py" \
    "$runtime_root/moshi-rag-mlx-config.json" \
    "$moshi_bf16_weight" \
    "$moshi_q8_pending" \
    --bits 8
/bin/mv "$moshi_q8_pending" "$moshi_q8_weight"

HF_HOME="$runtime_root/HuggingFace" \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_OFFLINE=1 \
    PYTHONPATH="$rag_checkout/site-packages" \
    "$shared_python" -c \
    "import torch; import moshi; assert torch.backends.mps.is_available()"
PYTHONPATH="$mlx_checkout/site-packages" \
    "$shared_python" -c "import mlx.core; import moshi_mlx"
DYLD_LIBRARY_PATH="$python_root/lib" \
    "$stt_binary" validate "$runtime_root/moshi-stt.toml"

marker="$runtime_root/.vibetalker-voice-runtime"
{
    echo "moshi=$moshi_revision"
    echo "moshi-rag=$rag_revision"
    /usr/bin/shasum -a 256 \
        "$repo_root/Patches/moshi-mlx-rag-apple-silicon.patch" \
        "$repo_root/Patches/moshi-mlx-app-sandbox-pipes.patch" \
        "$repo_root/Patches/moshi-mlx-streaming-stt.patch" \
        "$repo_root/Patches/moshi-mlx-nonblocking-log.patch" \
        "$repo_root/Patches/moshi-mlx-event-loop-fairness.patch" \
        "$repo_root/Patches/moshi-mlx-parent-termination.patch" \
        "$repo_root/Patches/moshi-mlx-proactive-completion.patch" \
        "$repo_root/Patches/moshi-mlx-retrieval-trigger.patch" \
        "$repo_root/Patches/moshi-rag-apple-silicon-conditioner.patch" \
        "$repo_root/scripts/convert-moshi-rag-candle-to-mlx.py" \
        "$repo_root/scripts/quantize-moshi-mlx.py" \
        "$proactive_prompt"
} > "$marker"

echo "Built the VibeTalker voice runtime from pinned GitHub sources in $runtime_root"
