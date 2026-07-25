#!/bin/bash
set -euo pipefail

repository=https://github.com/earendil-works/pi.git
revision=5a073885b5f23cd6125cda0927cf50acf2bf22fb
checkout="${1:-$PWD/Vendor/pi-mono}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

if [[ ! -d "$checkout/.git" ]]; then
    mkdir -p "$(dirname "$checkout")"
    git clone --filter=blob:none "$repository" "$checkout"
fi

git -C "$checkout" fetch origin "$revision"
git -C "$checkout" checkout --detach "$revision"

actual_revision="$(git -C "$checkout" rev-parse HEAD)"
if [[ "$actual_revision" != "$revision" ]]; then
    echo "error: Expected pi revision $revision, found $actual_revision"
    exit 1
fi

# The root `build` script refreshes generated provider catalogs from mutable
# third-party APIs before compiling. That makes an old Git revision depend on
# today's registry contents and has already produced an incompatible type in a
# pinned checkout. Install the lockfile, then compile the committed catalogs
# and packages in dependency order.
npm --prefix "$checkout" ci
npm --prefix "$checkout/packages/tui" run build
"$checkout/node_modules/.bin/tsgo" -p "$checkout/packages/ai/tsconfig.build.json"
npm --prefix "$checkout/packages/agent" run build
npm --prefix "$checkout/packages/coding-agent" run build
cp "$repo_root/PiExtension/vibetalker-tool-policy.ts" \
    "$checkout/vibetalker-tool-policy.ts"
cp "$repo_root/PiExtension/tool-manifest.json" \
    "$checkout/vibetalker-tool-manifest.json"

echo "Built pi coding agent from $repository at $revision"
