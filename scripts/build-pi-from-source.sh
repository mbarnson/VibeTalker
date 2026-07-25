#!/bin/bash
set -euo pipefail

repository=https://github.com/badlogic/pi-mono.git
revision=8eef62ed3ea62d646a7fad92fa583fc8d71fec17
checkout="${1:-$PWD/Vendor/pi-mono}"

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

npm --prefix "$checkout" install
npm --prefix "$checkout" run build

echo "Built pi coding agent from $repository at $revision"
