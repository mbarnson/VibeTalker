# Gate 5: pinned pi source baseline

Status: **source build, signed-app embedding, security fixtures, native RPC,
and typed sandbox edit passed; voice/status continuity pending**

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

Gate 5 remains open until the spoken path, grounded status exchange, window
reopen continuity, abort path, and proactive spoken completion pass together.

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
tools, and then completed a correlated `get_state` request.

`scripts/test-pi-tool-policy.mjs` imports that installed extension with the
same embedded Node executable used by the app, captures the tools registered
through pi's real extension API, and directly exercises their production
`execute` functions. The fixture passed all of the following:

- exact seven-tool manifest;
- ordinary file-tool write inside the workspace;
- absolute file-tool write outside the workspace denied;
- file-tool write through an in-workspace symlink to an outside directory
  denied;
- command-tool write inside the workspace;
- command-tool write to `/private/var/tmp` denied; and
- command-tool outbound TCP connection denied.

Gate 0 separately proves the outer App Sandbox and inherited child boundary
from within the signed app. A Swift launch-contract test additionally fixes
the pi environment to exactly `HOME`, `NODE_NO_WARNINGS`, `OPENSSL_CONF`,
`PATH`, `PI_CODING_AGENT_DIR`, and `TMPDIR`; ambient provider and host
credentials are not copied into the child. When coding authentication is
configured, exactly the selected provider's API-key variable is added.

These deterministic tool-boundary proofs pass without trusting a model to
choose a particular exploit.

## Job-lifecycle checkpoint

The native RPC client now normalizes pi's authoritative `agent_start`,
`tool_execution_start`, `tool_execution_end`, `turn_end`, `agent_end`, retry,
abort, stderr, and process-exit records into the Event Ledger. Tool activity
names the tool and bounded path evidence supplied by pi. Final state comes from
the assistant stop reason and `agent_end`, rather than prompt acceptance, so
the composer leaves active-job mode on completion, cancellation, failure, or
helper exit.

Synthetic protocol fixtures cover successful completion text, abort, provider
failure, and tool-path projection. The Xcode test bundle compiles those
fixtures. The Xcode 27 beta test-plan launcher on this machine still stalls
before emitting test results, so compilation is recorded separately from test
execution.

Computer Use then submitted a real harmless typed request through the signed
app with no provider credential configured. Pi returned its authoritative
`No API key found for the selected model` error; the ledger displayed the
failure, emitted no project-naming acceptance, and left the composer idle.
This proves the degraded prompt path.

With Anthropic selected through the development credential boundary, Computer
Use next submitted:

```text
Create a file named gate5-marker.txt containing exactly VibeTalker Gate 5
passed, then read it back to verify. Do not change any other file.
```

The ledger named `Workspace` in its committed acknowledgement, recorded pi's
`write` and `read` tool events for `gate5-marker.txt`, returned the composer to
idle, and published pi's grounded completion:

```text
Verified. The file `gate5-marker.txt` contains exactly
`VibeTalker Gate 5 passed`.
```

The resulting app-container file is 24 bytes. The direct read tool result and
assistant completion agree on its exact content.

## Coding credential boundary

No provider key is tracked, embedded in the app, or written to pi's
`auth.json`. The product UI stores a user-entered key as a generic password
created by VibeTalker itself in the Data Protection Keychain. The item is
restricted to the signed app's private
`$(AppIdentifierPrefix)org.barnson.VibeTalker` access group and uses
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. No helper reads the Keychain;
the main app supplies only the selected credential to the pi child. Existence
checks request attributes without decrypting the secret, and all Security
framework calls run on a dedicated actor rather than the main UI actor.

After the Apple developer agreement was accepted, Xcode refreshed the managed
Mac provisioning profile and signed the app with application identifier
`95S7RCGWWH.org.barnson.VibeTalker` and the matching private Keychain access
group. A synthetic non-secret item was saved, the app process was fully
terminated, and a normal relaunch recognized the item without an authorization
dialog. The fixture was then removed through the product UI. An earlier
experiment that pre-created a legacy login-Keychain item with the `security`
CLI was discarded because its creator ACL caused repeated password prompts.

For source-tree development only, `scripts/run-vibetalker-dev.sh` reads exactly
one selected provider key from the ignored `.env`, exports it to the app
without placing the value in argv, clears the other supported provider
variables, and launches the already-built product. The UI labels this source
`Development environment`. This path creates no Keychain item and therefore
causes no authorization prompts during iterative debug builds.

## Compatible provider configuration

The main Pi surface exposes explicit `OpenAI-compatible` and
`Responses-compatible` choices alongside the built-in providers. Both show a
base URL and model ID instead of assuming that every compatible server exposes
the same catalog. VibeTalker writes pi's `models.json` with the selected
`openai-completions` or `openai-responses` API identifier and a literal
`$OMLX_API_KEY` environment reference. The actual credential remains in the
app process/child environment and is never serialized into that file.

The signed app was launched with only `OMLX_API_KEY` supplied by the
development credential boundary. Computer Use selected
`Responses-compatible`, retained the default
`http://127.0.0.1:8000/v1` base URL, entered a synthetic model ID, ran Gate 0,
and started pi. VibeTalker generated the custom provider, issued pi's pinned
`set_model` RPC shape, and reached `RPC connected` without contacting the
model. The first acceptance run exposed a `modelID` versus `modelId` wire-key
mistake; the corrected key is fixed by a JSON-shape regression test.

Current oMLX main at
`4177294074b6d0394693760839eb8e0e367d4feb` registers
`POST /v1/responses`, streams Responses events over SSE, and persists
`previous_response_id` state. It does not register a WebSocket route or accept
`response.create` client events. OpenAI Responses WebSocket mode therefore
cannot be claimed for the local oMLX endpoint at this source revision. Pi's
pinned generic `openai-responses` implementation also uses HTTP/SSE; its
WebSocket transport is specific to the `openai-codex-responses` provider.
VibeTalker's native Interactor now requests that SSE stream and accepts output
only from a typed `response.completed` event; `response.failed`, `error`, and
premature stream termination are explicit failures rather than full-body or
protocol fallbacks.

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
