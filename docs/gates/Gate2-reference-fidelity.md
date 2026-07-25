# Gate 2 — Reference fidelity

Status: **GO**

The corrected source-built Moshi-RAG runtime passed the frozen
Reference-fidelity corpus across two independent runs.

The machine-readable evidence is
[`Fixtures/Gate2/results/reference-fidelity-bf16.json`](../../Fixtures/Gate2/results/reference-fidelity-bf16.json).
The frozen corpus and rubric are
[`Fixtures/Gate2/reference-fidelity-corpus.json`](../../Fixtures/Gate2/reference-fidelity-corpus.json).

## Acceptance result

| Run | Fully correct | Required | Contradictions | Result |
| --- | ---: | ---: | ---: | --- |
| `run-1` | 9/10 | at least 8/10 | 0 | PASS |
| `run-2` | 10/10 | at least 8/10 | 0 | PASS |
| Aggregate | 19/20 | at least 17/20 | 0 | PASS |

The PRD also requires zero direct contradictions. The mechanical rubric found
none.

## Protocol

The corpus and scoring rubric were frozen before the official run. Each turn:

1. Began encoding one canned fact through Moshi's `/api/reference` conditioner
   seam at the end of the spoken question, matching Moshi-RAG's asynchronous
   retrieval timing.
2. Spoke a question synthesized with the macOS `Samantha` voice at 185 words
   per minute, prefixed with `Moshi,`.
3. Kept one `/api/chat` WebSocket open across all ten turns in the run.
4. Captured the returned Opus audio, Moshi text events, and streaming input
   ASR.
5. Transcribed the actual rendered response audio with pinned
   `mlx-whisper==0.4.3` and
   `mlx-community/whisper-small-mlx` revision
   `45f3915923c7a79a5a5b5a7d909d39aeb0e5630e`.
6. Restarted the local runtime before the second independent run.

The evaluator scored the audible transcript when rendered audio was present
and otherwise scored Moshi's text stream.

The BF16 runtime was launched from the repository's pinned
`Vendor/voice-runtime` source build. The tested Moshi weight SHA-256 was
`a833601754bb6cb9b2d4730d808d7f261da607f64e18a00d7c0ad49456d6c0c3`.
The host ran macOS 27.0 build 26A5378j on arm64.

Reproduce the official evaluation from the repository root:

```sh
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-gate2-reference-fidelity.py \
  --precision bf16 \
  --output Fixtures/Gate2/results/reference-fidelity-bf16.json \
  --log-dir tmp/Gate2-official-logs
```

Raw response WAV files and process logs are intentionally written under the
ignored `tmp/` tree. The committed result records each response WAV's SHA-256
so retained local artifacts can be correlated with the scored evidence.

## Corrective findings

- The previous converted MLX checkpoint contained 216 tensors and no
  `depformer.slices.*` weights. Permissive `strict=False` loading silently left
  the speech depformer randomly initialized. That produced plausible grounded
  text alongside unrelated, repetitive audio.
- Kyutai's pinned `moshika-rag-candle-bf16` artifact already stores individually
  sliced depformer weights. The tracked Candle-to-MLX converter now maps the
  first eight generated audio-codebook slices explicitly. The corrected
  checkpoint contains 526 tensors, including 39 tensors for every speech
  slice, and passes `strict=True` loading.
- MLX now uses Moshi-RAG's source-native sampling policy: text temperature 0.7
  with top-k 25, and audio temperature 0.8 with top-k 250.
- The streaming STT receiver yields a positive 5 ms scheduling quantum for
  each return event. A zero-duration yield left it continuously runnable and
  starved Mimi/Opus work on the shared asyncio loop.
- Input ASR captured all 20 questions. Nineteen rendered responses contained
  the exact required fact. The single partial was `cedar`, which synchronized
  Moshi text emitted exactly while the pinned Whisper evaluator transcribed the
  audible word as `keeter`.

## Signed-app live validation

The signed Xcode debug product imported the final pinned-source runtime and
started the supervised ARC encoder, Kyutai STT worker, corrected Q8 Moshi-RAG
server, and native Coordinator adapter. CoreAudio reported the built-in
three-channel MacBook Pro microphone as the default 48 kHz input and the
built-in speakers as the default output; BlackHole was absent.

Safari connected to the packaged Moshi client with the source-native sampler
settings. Across a 2:01.23 live session, the client reported 0:00.00 missed
audio and 181 ms final latency. A speaker-generated test prompt was suppressed
by macOS echo cancellation and therefore is not claimed as semantic microphone
recognition evidence. The session does establish the signed application's
source-built startup, built-in device route, full-duplex transport, clean
playback, and supervised shutdown.

## Release decision

Gate 2 passes. The native Moshi-RAG full-duplex speech architecture remains
eligible for the dependent PRD gates.
