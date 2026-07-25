#!/bin/bash
set -euo pipefail

source_root="$SRCROOT/Vendor/voice-runtime"
runtime_root="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/voice-runtime"
legacy_helper_root="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/voice-runtime"
python_helper="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/vibetalker-python"
python_library_link="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/lib"
entitlements="$SRCROOT/VibeTalker/Resources/node-helper.entitlements"

required=(
    "$source_root/.vibetalker-voice-runtime"
    "$source_root/Python/bin/python3.12"
    "$source_root/moshi-mlx/site-packages/moshi_mlx/__init__.py"
    "$source_root/moshi-rag/site-packages/moshi/__init__.py"
)
for path in "${required[@]}"; do
    if [[ ! -e "$path" ]]; then
        echo "error: Missing staged voice runtime artifact: $path"
        exit 1
    fi
done

rm -rf "$runtime_root" "$legacy_helper_root" "$python_helper" "$python_library_link"
mkdir -p \
    "$runtime_root/moshi-mlx" \
    "$runtime_root/moshi-rag" \
    "$(dirname "$python_helper")"
/usr/bin/rsync -a --exclude "/bin/" "$source_root/Python/" "$runtime_root/Python/"
/usr/bin/rsync -a \
    "$source_root/moshi-mlx/site-packages/" \
    "$runtime_root/moshi-mlx/site-packages/"
/usr/bin/rsync -a \
    "$source_root/moshi-rag/site-packages/" \
    "$runtime_root/moshi-rag/site-packages/"
/bin/cp "$source_root/Python/bin/python3.12" "$python_helper"
/bin/ln -s "Resources/voice-runtime/Python/lib" "$python_library_link"

while IFS= read -r -d '' binary; do
    if /usr/bin/file -b "$binary" | /usr/bin/grep -q "Mach-O"; then
        /usr/bin/codesign --remove-signature "$binary" 2>/dev/null || true
        /usr/bin/codesign \
            --force \
            --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --options runtime \
            "$binary"
    fi
done < <(
    /usr/bin/find "$runtime_root" -type f \
        \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) \
        -print0
)

/usr/bin/codesign --remove-signature "$python_helper" 2>/dev/null || true
/usr/bin/codesign \
    --force \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$entitlements" \
    "$python_helper"

echo "Embedded and signed the pinned Python voice runtime."
