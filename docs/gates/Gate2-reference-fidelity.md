# Gate 2 — Reference fidelity

Status: **NO-GO**

The frozen Reference-fidelity corpus failed both independent runs. Moshi did
not produce any required Reference fact in the scored response.

The machine-readable evidence is
[`Fixtures/Gate2/results/reference-fidelity-bf16.json`](../../Fixtures/Gate2/results/reference-fidelity-bf16.json).
The frozen corpus and rubric are
[`Fixtures/Gate2/reference-fidelity-corpus.json`](../../Fixtures/Gate2/reference-fidelity-corpus.json).

## Acceptance result

| Run | Fully correct | Required | Contradictions | Result |
| --- | ---: | ---: | ---: | --- |
| `run-1` | 0/10 | at least 8/10 | 0 | FAIL |
| `run-2` | 0/10 | at least 8/10 | 0 | FAIL |
| Aggregate | 0/20 | at least 17/20 | 0 | FAIL |

The PRD also requires zero direct contradictions. The mechanical rubric found
none of its frozen forbidden phrases, but this does not rescue the gate:
every turn omitted its required fact.

## Protocol

The corpus and scoring rubric were frozen before the official run. Each turn:

1. Injected one canned fact through Moshi's `/api/reference` conditioner seam.
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
and otherwise scored Moshi's text stream. No required phrase appeared in
either channel, so the channel selection did not affect the 0/20 result.

The BF16 runtime was launched from the repository's pinned
`Vendor/voice-runtime` source build. The tested Moshi weight SHA-256 was
`544996b57b40cf3bf99c3ddcbd1bbd1da195a04b4ce43846d576bb801e75c867`.
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

## Observations

- Input ASR captured all 20 questions and consistently preserved the operative
  noun phrase. The failure is downstream of microphone transport and input
  speech recognition.
- Only 11 of 20 turns produced non-empty Whisper transcripts of returned
  audio. Fifteen produced some Moshi text event, but none contained the
  required fact.
- Audible responses frequently repeated a short sentence many times, matching
  the stuttering observed in manual app testing.
- Several turns produced no usable audible response.
- The final turn repeated an unrelated phrase with unsafe-sounding content.
  The exact generated text is retained in the machine result for diagnosis,
  but should not be surfaced as normal product output.

## Release decision

Per PRD v2, this result invalidates the current Moshi-as-speech-interface
architecture. Dependent work must stop until the product promise or
architecture is deliberately revised.

A local CPU Kokoro prototype is a credible narrow speech-delivery candidate:
using the existing `kokoro-onnx` prior art and local model files, the sentence
“The verification color is cobalt.” synthesized in 1.102 seconds cold, yielded
2.112 seconds of audio, and independently transcribed exactly. That prototype
is not treated as a Gate 2 pass and has not been silently substituted into the
product. A product decision is required before replacing Moshi's generated
speech path.
