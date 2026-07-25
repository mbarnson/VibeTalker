# VibeTalker

VibeTalker is a native, sandboxed macOS voice front end for a pinned pi coding
agent. Moshi-RAG owns full-duplex speech and local streaming ASR; a
Responses-compatible Interactor supplies fast conversational context; pi owns
the coding loop. The app keeps ambient speech outside the filesystem and shell
capability boundary.

Slice One targets the acceptance Mac: an Apple M4 Max running macOS 27 and
Xcode 27. The complete product contract and measured gate results live in
[`docs/PRDv2.md`](docs/PRDv2.md) and [`docs/gates`](docs/gates).

## Checkout to first conversation

Once prerequisites and model downloads are present, the intended first-run path
is:

```sh
git clone git@github.com:mbarnson/VibeTalker.git
cd VibeTalker
scripts/bootstrap-from-source.sh
scripts/run-vibetalker-dev.sh
```

The bootstrap does not use registry substitutes for the two product runtimes.
It checks out and builds:

- `kyutai-labs/moshi` and `kyutai-labs/moshi-rag` at the revisions in
  `Dependencies/upstreams.json`, with the tracked Apple-Silicon patches;
- `earendil-works/pi` at its pinned Git revision; and
- the signed, sandboxed VibeTalker app through `xcodebuild`.

The first source build downloads roughly 32 GB of pinned model artifacts and is
not part of the ten-minute warmed first-run target. Later builds reuse the
revision-addressed cache.

### Prerequisites

- Apple Silicon Mac; the accepted configuration is an M4 Max with 128 GB.
- macOS 27 and Xcode 27 selected for command-line use.
- An Apple Development signing identity for the team configured in the Xcode
  project.
- Homebrew at `/opt/homebrew`, with current Node and OpenSSL 3.
- Python 3.12.11, Rust/Cargo, npm, Git, and optionally `uv`.
- Hugging Face access to the pinned model repositories.
- An OpenAI API key for the default Interaction provider and an Anthropic API
  key for the default pi coding provider.

The source builders fail early with a specific message when a required revision,
tool, model, or generated artifact is missing.

### Credentials without Keychain prompts

For development, create an untracked `.env`:

```text
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
```

`.env` is ignored by Git. `scripts/run-vibetalker-dev.sh` reads only the keys
for the two explicitly selected providers, removes other supported provider
variables, and launches the built app without putting credentials in argv.
Its release-safe default is hosted OpenAI Responses for Interaction and hosted
Anthropic for coding.

Pass provider names explicitly to use a different supported pairing. For
example, the signed pi/full-duplex acceptance gate uses the current OpenAI key
for both roles:

```sh
scripts/run-vibetalker-dev.sh openai openai
```

For normal app launches, use each provider's SecureField and **Save** button.
VibeTalker creates a device-only Data Protection Keychain item. The secret is
not stored in app preferences, `auth.json`, the event ledger, the app bundle,
or this repository. The app passes only the selected credential to the child
that needs it. Do not pre-create a legacy login-Keychain item with the
`security` command; that is the path that causes repeated password prompts.

### One-time model import

Executable runtime code is signed into the app, while the large mutable model
payload remains outside the signature:

1. In VibeTalker, click **Import Staged Runtime…**.
2. Select the `Vendor/voice-runtime` folder itself.
3. Wait until every managed voice-runtime artifact shows **Ready**.

The signed app validates the pinned marker and copies model data into its own
Application Support container. The source builder intentionally cannot write
there.

### Start the product

1. Click **Run Preflight** and require green results for helper stdio, Node JIT,
   and the nested command sandbox.
2. Confirm the Interaction and Coding provider rows show a configured
   credential.
3. Click **Start Pi** and wait for **RPC connected**.
4. Click **Start Local Voice**.

The last action starts the local STT, ARC, and Moshi processes. Only after Moshi
is ready does VibeTalker open `http://127.0.0.1:8999` in the default browser.
That page owns microphone capture, so grant microphone permission to the
browser when macOS asks. Moshi audio plays through the current system output
device; VibeTalker does not create or select an aggregate or virtual device.

Speak a normal question, then ask for a harmless coding change. A committed job
acknowledgement names the `Workspace` sandbox. Conversation remains available
while pi works; ask what pi is doing for a grounded status response. Completion
appears in the Pi Console and is injected back into Moshi for proactive speech.

For unattended acceptance only, set
`VIBETALKER_ACCEPTANCE_AUTOSTART=1`. The development-only launch seam runs
preflight, waits for pi RPC, and starts the local voice runtime without opening
the Moshi browser surface or automating the app UI. It is not persisted and
normal launches remain manual.

## Provider modes and egress

Fresh configuration uses **OpenAI Responses (WebSocket)** for Interaction and
Anthropic for coding. Voice audio, Mimi, Moshi-RAG, ARC conditioning, and STT
stay local. Committed transcripts go to the selected Interaction provider, and
workspace context used by pi can go to the selected coding provider.

**Responses-compatible (WebSocket)** supports a local endpoint such as
`http://127.0.0.1:8000/v1/responses`. It remains available for development, but
Gate 6 found that concurrent local MLX generation can disturb Moshi under
active audio load. The app labels that choice rather than silently changing
providers. There is no cloud fallback.

## Build and verification

Build only:

```sh
xcodebuild \
  -project VibeTalker.xcodeproj \
  -scheme VibeTalker \
  -destination 'platform=macOS' \
  build
```

Run the native test target:

```sh
xcodebuild \
  -project VibeTalker.xcodeproj \
  -scheme VibeTalker \
  -destination 'platform=macOS' \
  test -only-testing:VibeTalkerTests
```

Run the two-turn live hosted Responses WebSocket smoke test:

```sh
xcrun swiftc \
  -o /tmp/vibetalker-responses-websocket-smoke \
  VibeTalker/Models/InteractionModels.swift \
  VibeTalker/Services/Interactor.swift \
  scripts/run-responses-websocket-smoke.swift

set -a
source .env
set +a
/tmp/vibetalker-responses-websocket-smoke
```

The Moshi acceptance fixtures inject PCM directly over loopback and do not play
through speakers:

```sh
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-gate1-optimized-topology.py

Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-full-duplex-soak.py

set -a
source .env
set +a
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-conversation-naturalness.py

# With the signed app reporting Coordinator ready and pi RPC connected:
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-signed-pi-duplex.py
```

The full-duplex soak runs for ten minutes, retains component logs under
`tmp/Acceptance-logs/`, and writes its frozen summary to
`Fixtures/Acceptance/full-duplex-soak-q8.json`.

The conversation-naturalness run captures the frozen 20-turn Moshi corpus
without opening a Core Audio output device. It reloads `OPENAI_API_KEY` from
the developer's untracked `.env` and sends only each captured response,
its frozen spoken prompt, and its reference answer to `gpt-realtime-2.1`
over OpenAI's server-to-server Realtime WebSocket for native audio evaluation.
This hosted evaluator is acceptance instrumentation; the product Interactor
continues to use the selected OpenAI or oMLX Responses WebSocket provider.
The frozen q8 result passed 18 of 20 turns and is retained at
`Fixtures/Acceptance/conversation-naturalness-q8.json`.

The signed pi-duplex harness connects to the app-supervised runtime rather
than starting a second Moshi process. It commits one fixed coding task and
three grounded status requests through the app-owned Coordinator while
streaming ten minutes of speakerless PCM. See
[`docs/gates/Gate8-signed-pi-duplex.md`](docs/gates/Gate8-signed-pi-duplex.md).

Additional source-build detail is in
[`docs/voice-runtime-build.md`](docs/voice-runtime-build.md). Gate evidence is
committed under `Fixtures/`; generated runtimes, models, audio, `.env`, and
developer checkouts remain ignored.

## Security boundary

VibeTalker uses App Sandbox and Hardened Runtime. The app-container `Workspace`
is the only project exposed to pi. The pinned tool-policy extension constrains
file tools to that root, and pi shell commands run inside a fixed
`sandbox-exec` profile that denies outbound networking and outside-workspace
writes. Spoken confirmation changes intent state only; it never widens OS
capabilities.
