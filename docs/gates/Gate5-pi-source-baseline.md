# Gate 5: pinned pi source baseline

Status: **source build, signed-app embedding, and native RPC handshake passed;
sandboxed coding loop pending**

## Source identity

- Repository: `https://github.com/earendil-works/pi.git`
- Revision: `5a073885b5f23cd6125cda0927cf50acf2bf22fb`
- Package: `packages/coding-agent`
- Integration: the source-built `dist/rpc-entry.js`, not a global or registry
  pi executable

The revision is pinned in `Dependencies/upstreams.json` and enforced by
`scripts/build-pi-from-source.sh`.

## Reproducible build decision

The repository root `npm run build` is not revision-pure: the `pi-ai` build
regenerates provider and image-model catalogs from live external APIs before
TypeScript compilation. On July 24, 2026, the live OpenCode catalog introduced
an `openai-responses` API value that the pinned revision's provider type did
not accept, causing `TS2322`.

VibeTalker therefore installs the pinned lockfile with `npm ci` and compiles
the committed generated catalogs package-by-package:

1. `packages/tui`
2. `packages/ai` via the workspace-pinned `tsgo`, without generation
3. `packages/agent`
4. `packages/coding-agent`

This produced the executable RPC entry point at
`packages/coding-agent/dist/rpc-entry.js`.

## RPC handshake

The source-built entry point was launched with an isolated temporary
`HOME`/`PI_CODING_AGENT_DIR` and all ambient extensions, skills, prompt
templates, themes, context files, and tools disabled. A correlated JSONL
command:

```json
{"id":"smoke-1","type":"get_state"}
```

returned a successful `get_state` response with the same `smoke-1` identifier,
an idle session, zero messages, and no configured model. This proves the pinned
source build and stdin/stdout protocol boundary without sending a provider
request or loading host configuration.

Gate 5 remains open until the native app dispatches a harmless app-container
edit through a configured model and passes the write/network escape fixtures.

## Tool-policy load checkpoint

The tracked `PiExtension/vibetalker-tool-policy.ts` replaces all seven tools in
the pinned manifest: `read`, `bash`, `edit`, `write`, `grep`, `find`, and `ls`.
Every file-like path is resolved against the canonical workspace path,
including existing symlink targets and the nearest existing ancestor of a new
path. Bash uses a fixed nested `sandbox-exec` profile that permits writes only
inside the workspace and `/private/tmp` and denies networking.

The build script installs the extension and its manifest alongside the pinned
pi checkout. In the isolated RPC fixture, pi loaded only this explicit
extension, reported all seven expected overrides with no missing or unknown
tools, and then completed a correlated `get_state` request. Model-driven
write/network escape fixtures remain required before Gate 5 passes.

## Signed native-app checkpoint

After compilation, `npm prune --omit=dev` reduces the pinned checkout to the
runtime dependency graph. Xcode's `Embed Pi Runtime` phase verifies the exact
revision and copies that graph, the four compiled package outputs, and the
tracked policy files into `Contents/Resources/Runtime/pi`.

The signed sandboxed app passed Gate 0, detected all three embedded pi
artifacts, loaded the seven-tool extension, and completed a correlated
`get_state` request. The UI reported `RPC connected` and:

```text
Pinned source-built pi RPC session ready
```

The first native attempt exposed a hidden host dependency in the Homebrew Node
build: OpenSSL tried to read `/opt/homebrew/etc/openssl@3/openssl.cnf`, which
the app sandbox correctly denied. VibeTalker now sets `OPENSSL_CONF=/dev/null`
for the child, so the packaged runtime does not depend on the developer
machine's Homebrew configuration. Child stderr is also forwarded to the
redacted native ledger so future early-runtime failures remain diagnosable.
