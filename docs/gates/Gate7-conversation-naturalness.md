# Gate 7 — Frozen conversation naturalness

Status: **corpus and rubric frozen; evaluation pending**

PRDv2 requires a fixed 20-turn conversation run with ten factual prompts and
ten open-ended prompts. At least 16 turns must pass, and ad hoc freeform turns
cannot replace failures. The complete corpus and Boolean rubric are frozen in
`Fixtures/Acceptance/conversation-naturalness-corpus.json` before the first
evaluation run.

## Architecture boundary

This gate does not change VibeTalker's product transport:

- The product Interactor remains the actor-isolated OpenAI or oMLX
  `/v1/responses` client in `ResponsesInteractor`.
- Moshi-RAG remains the local full-duplex media provider and upstream browser
  audio surface required by Slice One.
- The acceptance harness feeds synthesized prompts and captures Moshi PCM over
  direct loopback. It never opens a Core Audio output device.
- Only after capture, a hosted OpenAI Realtime model hears each response and
  returns a text-only Boolean rating. This is an external evaluator, not a
  speech or Interaction fallback.

VoiceClaw commit `3aa23f509c39897ecc8052c33c7b241faad6327c`
is the pinned Swift prior art for actor-owned services, `AsyncStream` event
delivery, persistent WebSocket state, and lifecycle correlation. That snapshot
uses a stopped-recording ASR / streamed gateway text / local TTS sequence; it
is not itself an OpenAI Realtime or full-duplex implementation. VibeTalker
adopts its service-boundary pattern without replacing Moshi's media loop.

## Evaluator transport and data boundary

The harness is a trusted server-side Python process, so it uses the
server-to-server Realtime WebSocket at
`wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`. OpenAI recommends
WebRTC for browser and mobile clients, and WebSocket for server-to-server
Realtime integrations. The harness sends 24 kHz PCM with
`input_audio_buffer.append`, commits it explicitly with VAD disabled, and
requests a text-only `Response`.

The current `OPENAI_API_KEY` is loaded from the developer's ignored `.env`
immediately before the run. It is never copied into a fixture, source file,
command output, or Git commit. Each evaluator request receives only:

- the captured Moshi response audio for one frozen turn;
- that turn's spoken prompt;
- that turn's frozen reference answer and scoring instructions.

The official transport references are OpenAI's
[Realtime WebSocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket),
[Realtime WebRTC guide](https://developers.openai.com/api/docs/guides/realtime-webrtc),
and
[Realtime conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations).

## Frozen pass rule

A turn passes only when all conditions are true:

1. The audible response addresses the prompt.
2. It supplies the material factual answer or a substantive open-ended answer.
3. It is intelligible and conversational without conspicuous stutter,
   chopped words, repeated fragments, or dominant noise.
4. It does not claim an unauthorized action or external state change.
5. Captured PCM lasts at least two seconds, p99 output-packet gap is below
   150 milliseconds, and maximum packet gap is below 500 milliseconds.

The gate passes only when all 20 frozen turns run and at least 16 pass.
Factual and open-ended results are reported separately.

## Reproduction

```sh
set -a
source .env
set +a
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-conversation-naturalness.py
```

Captured WAV files and retained component logs remain ignored under `tmp/`.
The summary will be committed as
`Fixtures/Acceptance/conversation-naturalness-q8.json` after the frozen run.
