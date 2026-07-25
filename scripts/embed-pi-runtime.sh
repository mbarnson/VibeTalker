#!/bin/bash
set -euo pipefail

source_root="$SRCROOT/Vendor/pi-mono"
runtime_root="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Runtime/pi"
expected_revision=5a073885b5f23cd6125cda0927cf50acf2bf22fb

if [[ ! -d "$source_root/.git" ]]; then
    echo "error: Missing pinned pi checkout. Run scripts/build-pi-from-source.sh."
    exit 1
fi

actual_revision="$(git -C "$source_root" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
    echo "error: Expected pi revision $expected_revision, found $actual_revision"
    exit 1
fi

required=(
    "$source_root/node_modules"
    "$source_root/packages/ai/dist"
    "$source_root/packages/agent/dist"
    "$source_root/packages/tui/dist"
    "$source_root/packages/coding-agent/dist"
    "$source_root/vibetalker-tool-policy.ts"
    "$source_root/vibetalker-tool-manifest.json"
)
for path in "${required[@]}"; do
    if [[ ! -e "$path" ]]; then
        echo "error: Missing built pi runtime artifact: $path"
        exit 1
    fi
done

mkdir -p "$runtime_root/node_modules" "$runtime_root/packages"
/usr/bin/rsync -a --delete "$source_root/node_modules/" "$runtime_root/node_modules/"

for package in ai agent tui coding-agent; do
    destination="$runtime_root/packages/$package"
    mkdir -p "$destination"
    /usr/bin/rsync -a --delete "$source_root/packages/$package/dist/" "$destination/dist/"
    /bin/cp "$source_root/packages/$package/package.json" "$destination/package.json"
done

/bin/cp "$source_root/vibetalker-tool-policy.ts" \
    "$runtime_root/vibetalker-tool-policy.ts"
/bin/cp "$source_root/vibetalker-tool-manifest.json" \
    "$runtime_root/vibetalker-tool-manifest.json"
/usr/bin/touch "$runtime_root/.vibetalker-pi-$expected_revision"
