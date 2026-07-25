# Gate 6 — Local-model coexistence

Status: **NO-GO for concurrent local oMLX plus Moshi**

This gate keeps memory capacity and shared-model execution contention as two
separate results. The target machine has enough unified memory to load the
tested models. It does not have enough independent Metal execution capacity to
keep Moshi audio healthy while oMLX is actively generating.

The compact machine-readable record is
[`Fixtures/Gate6/results/local-coexistence-summary.json`](../../Fixtures/Gate6/results/local-coexistence-summary.json).

## Memory coexistence

The 128 GB M4 Max retained about 80 percent free memory during the observed
coexistence runs. Memory pressure and swap were not the limiting signals.
Moshi-RAG and the tested Qwen oMLX models fit together.

Verdict: **PASS for capacity only.** This result says nothing about realtime
audio health or Metal scheduling.

## Shared-model contention

With Moshi active, concurrent Responses requests through local oMLX produced:

| Interaction model | Median | P95 | Moshi audio result |
| --- | ---: | ---: | --- |
| `mlx-community--Qwen3-4B-Instruct-2507-4bit` | 2.422 s | 2.527 s | Missed audio increased; latency exceeded 9 s and later 15 s |
| `mlx-community--Qwen3-0.6B-8bit` | 1.531 s | 1.633 s | Missed audio and latency still increased |

The smaller model reduced Interaction latency but did not remove the realtime
audio regression. This rules out memory exhaustion as the explanation and
identifies shared MLX/Metal execution as the limiting dimension.

An optimized follow-up replaced the 13 GB BF16 Moshi MLX weights with a 7.6 GB
q8 artifact generated from the pinned GitHub source checkout. With the q8
Moshi server loaded and its browser WebSocket connected, a balanced 15-turn
sample through the local Qwen 4B Responses endpoint produced 15/15 valid
results, 1.013 s median, 1.099 s P95, and no turns over 3 seconds. The Moshi
page reported zero missed audio during that run.

This is encouraging but does not reverse the gate: the automated session did
not produce Moshi output audio, so it did not reproduce the sustained
full-duplex inference load that exposed the BF16 underruns. The q8 result is a
qualified coexistence improvement, not evidence for the PRD's ten-minute
full-duplex acceptance condition.

The attempted CPU-only oMLX path failed with
`KeyError: max_recommended_working_set_size`; that server path is not a
supported CPU escape hatch.

Verdict: **FAIL.** A local oMLX request is enough to disturb Moshi, so a
long-running local pi generation cannot satisfy the PRD's ten-minute
full-duplex acceptance condition.

## Hosted Responses comparison

To remove the second local MLX workload, the frozen 100-turn corpus was run
against the OpenAI Responses API using `gpt-5.6-luna` with
`reasoning.effort = none`:

- 100/100 structurally and semantically valid results
- median 1.046080 s
- P95 2.222713 s
- two turns over 3 s

The full raw result is
[`Fixtures/Gate6/results/openai-luna-interactor.json`](../../Fixtures/Gate6/results/openai-luna-interactor.json).
It is a useful coexistence mitigation, but it is **not** reported as a latency
pass: the PRD allows P95 at most 2 seconds and at most one turn over 3 seconds.

OpenAI documents `reasoning.effort = none` as the low-latency baseline for
latency-sensitive work. Priority processing is documented as lower and more
consistent latency, but it carries premium pricing and is not intended for
evaluation traffic, so this gate neither enabled it silently nor used it to
make the benchmark appear to pass:

- <https://developers.openai.com/api/docs/guides/latest-model>
- <https://developers.openai.com/api/docs/guides/priority-processing>

## Release decision

The Slice One release configuration must not run local oMLX generation while
Moshi is active. A hosted Responses-compatible Interaction provider removes
one source of contention, but a local oMLX coding provider would still contend
when pi works. Therefore the no-underrun release path requires hosted
Interaction and coding providers, or an explicit product revision that
serializes local coding work outside an active voice session.

VibeTalker exposes the provider choices without a silent fallback. The user
must knowingly select and configure the release path. The existing local
Responses-compatible mode remains available for development and measurement,
but it is not Gate 6-approved for concurrent full-duplex use.

### Release-default transport

The app now makes the Gate 6-approved choice explicit for a fresh
configuration:

- Interaction defaults to hosted OpenAI Responses using
  `gpt-5.6-luna`, the same low-latency model measured above.
- Both Interaction choices use Responses WebSocket mode. The configured
  `http` or `https` endpoint is upgraded to `ws` or `wss` internally.
- The hosted choice is labeled as the release path. The local
  Responses-compatible choice remains available and is labeled as a
  development path that can disrupt active Moshi audio under Metal load.
- Coding continues to default to hosted Anthropic. No provider silently falls
  back to another provider or transport.
- `scripts/run-vibetalker-dev.sh` now follows the same release-safe default
  (`openai` Interaction plus `anthropic` coding); local/local remains an
  explicit command-line choice for measurement.

The native Interactor maintains one persistent WebSocket and sends a
`response.create` text frame per committed utterance. It retains the completed
response ID and sends only the new utterance with `previous_response_id` on the
next turn. With `store=false`, an evicted continuation or the server's
60-minute connection limit closes the socket and restarts a full request chain
without changing providers. A two-turn live smoke test is reproducible with
`scripts/run-responses-websocket-smoke.swift`.

The transport follows OpenAI's published WebSocket mode and event contract:

- <https://developers.openai.com/api/docs/guides/websocket-mode>
- <https://developers.openai.com/api/reference/resources/responses/websocket-events>

The accepted result is frozen at
`Fixtures/Gate6/results/openai-responses-websocket-smoke.json`. The first turn
completed in 1.425 seconds and the context-dependent continuation completed in
0.731 seconds on the same persistent connection. Both returned distinct
provider response IDs and valid typed Interaction output. The API key was read
from the process environment and was neither printed nor written to the
fixture.
