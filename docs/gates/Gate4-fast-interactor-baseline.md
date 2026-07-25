# Gate 4: fast Interactor baseline

Status: **passed — frozen 100-turn oMLX Responses corpus, native non-model path,
and Interaction-miss language comparison completed**

## Current checkpoint

`ConversationCoordinator` is the sole voice-turn admission boundary. It tracks
the active voice session and the newest committed revision for each utterance,
then rechecks those identities after every awaited dependency. A superseded
Interaction result cannot dispatch pi or reach Reference delivery.

The Interactor still owns typed `/v1/responses` output validation. The
Coordinator treats an optional Pi Request as data, dispatches it through a
separate capability, and constructs action acknowledgements only from the
authoritative Pi receipt:

- start: `Work started in <project>.`
- cancel: `Cancellation requested for <project>.`
- status: `<project>: <grounded status>`

Interactor prose is never allowed to claim that work started. A mismatched Pi
receipt, invalid project/status evidence, Interactor failure, dispatch failure,
or Reference-delivery failure is explicit and cannot publish a false
acknowledgement.

Interactor timeout, provider failure, cancellation, and malformed output now
produce a ledger-visible Interaction miss and a bounded fallback Reference
without dispatching pi. The frozen policy uses neutral wording for ordinary
conversation and adds `no work was started` only when a deterministic verb
heuristic finds a likely action request. The heuristic changes wording only;
it has no dispatch authority.

Voice and Pi Console starts now pass through one shared Coordinator policy.
Direct in-workspace requests may dispatch, destructive or ambiguous requests
create a correlated 30-second proposal, and external or project-changing
requests are refused. Proposals record identity, normalized action, origin,
project, risk, and expiry. Confirmation must arrive through the proposal's
original control channel; unrelated, late, cross-channel, and voice-session
changes expire it visibly.

Xcode `test-without-building -only-testing:VibeTalkerTests` executes focused
fixtures proving:

- a valid start request reaches Pi before the grounded project-naming
  Reference is delivered;
- a stale transcript revision is rejected before a second Interactor call; and
- a status request paired with a start receipt publishes no Reference.

`PiJobController` is now the authoritative lifecycle state machine behind the
typed Pi Console and is also the `PiRequestDispatching` capability intended for
voice turns. It serializes start admission across actor suspension, grounds
status in Pi lifecycle events, and preserves cancellation when a delayed prompt
acknowledgement or `agent_start` event arrives. A terminal `agent_end` without
assistant prose remains a grounded completion rather than receiving an invented
summary.

Additional executed fixtures cover second-start rejection, event-grounded
completion, summary-free completion, and the cancellation-versus-delayed-start
race.

The live `AppModel` now constructs one `ConversationCoordinator` per voice
session with the shared `PiJobController` used by typed console input. It
configures the user-selected `/v1/responses` endpoint and model, reads the
Responses-compatible credential from the development environment or Keychain,
and tears down the Coordinator state with the supervised voice processes.

A loopback-only native adapter exposes the pinned Moshi-RAG
`POST /v1/chat/completions` contract. It extracts the newest `Human:` turn,
routes that committed utterance through the real Coordinator, and returns only
the matching delivered Reference. Identical Moshi `<ret>` retries share one
in-flight Interaction task, so a retry cannot double-dispatch a Pi Request.
The supervised Moshi environment receives only the loopback adapter URL, a
fixed internal model name, and an internal loopback token; the configured oMLX
credential is not copied into that child environment.

The packaged, source-pinned MLX runner now connects committed streaming ASR to
this loopback boundary, sends the returned text to the ARC Reference Encoder,
and queues the resulting conditioning frames into the live Moshi model loop.
A live signed-app run accepted and queued proactive and committed References;
the pinned browser client remained connected to the supervised local service.
The executed unit target also includes a real URLSession request across the
loopback boundary and focused policy, expiry, confirmation, and failure
fixtures.

## Native non-model overhead

`scripts/run-gate4-native-overhead.swift` compiles against the production
Interactor, Coordinator, policy, Moshi bridge, and Reference HTTP client. A
custom in-process `URLProtocol` replaces only model computation with a valid
typed Responses SSE event and returns a 204 from the Reference endpoint. The
100-turn result retained at
`Fixtures/Gate4/results/native-overhead-summary.json` is:

- 0.000249-second median;
- 0.000294-second p95; and
- 0.000426-second maximum.

This measures native Responses request construction and URLSession transport,
SSE and structured-output decoding, local utterance binding, deterministic
intent reconciliation, Interaction validation, Coordinator policy, the Moshi
Reference bridge, and Reference HTTP encoding and transport. It does **not**
measure speech endpointing, real loopback socket scheduling, model inference,
or Moshi's audio rendering. Those remaining endpoints must be measured in the
signed-app voice test and are not silently attributed to the model.

Subtracting the native result from the product SLOs leaves these operational
model-and-unmeasured-audio allowances:

- all-turn Reference p95: 1.999706 seconds;
- committed dispatch acknowledgement median: 1.499751 seconds;
- committed dispatch acknowledgement p95: 2.499706 seconds; and
- first-audible status p95: 1.999706 seconds.

As the PRD notes, subtracting independent percentiles is a working budget for
Gate 6, not a claim that the distributions compose exactly.

## Interaction-miss language

The frozen corpus at `Fixtures/Gate4/interaction-miss-corpus.json` contains ten
ordinary questions and ten direct action requests. Ordinary turns deliberately
use words such as “fix,” “test,” “build,” and “change” in informational
questions so a bag-of-words heuristic cannot pass by construction.

`scripts/run-gate4-miss-policy.swift` compares the always-neutral wording with
the production deterministic heuristic. The retained result at
`Fixtures/Gate4/results/interaction-miss-policy-summary.json` is:

- heuristic-gated: explicit non-dispatch clarity on 10/10 action turns and
  0/10 ordinary turns;
- always-neutral: explicit non-dispatch clarity on 0/10 action turns and
  0/10 ordinary turns; and
- 20/20 production classifications match the frozen expectation.

The first heuristic revision matched an action verb anywhere in the
transcript. The comparison rejected that design because ordinary questions
such as “How do I fix a parser?” would receive the disruptive “no work was
started” clause. The release policy recognizes only direct imperatives and
common polite request openings. Gate 4 therefore freezes the heuristic-gated
variant: ordinary misses remain conversational, while likely action misses
state explicitly that no work began. The heuristic still affects wording only
and has no dispatch authority.

## Frozen Responses corpus

The frozen corpus at `Fixtures/Gate4/latency-corpus.json` contains exactly 60
ordinary conversation turns, 20 direct dispatch turns, and 20 grounded-status
turns. `scripts/run-gate4-interactor.py` sends the same strict Responses schema
and developer contract as the native Interactor, enforces a hard per-turn
deadline, records raw and reconciled intent, and calculates nearest-rank
percentiles.

The viable local model is
`mlx-community--Qwen3-4B-Instruct-2507-4bit`. The smaller
`mlx-community--Qwen3-0.6B-8bit` was rejected despite roughly 0.46-second
median latency: before explicit examples it classified 0/3 direct requests
and 0/3 status requests, and after explicit rules it over-dispatched all three
ordinary questions in the balanced smoke slice.

The final warmed 4B run used the source checkout at
`/Users/patbarnson/devel/omlx`, oMLX 0.5.3, on loopback with tiered caching
disabled. The retained aggregate result is
`Fixtures/Gate4/results/qwen3-4b-interactor-summary.json`:

- 100/100 final validated dispositions;
- 0.990646-second median and 1.108751-second p95 across all References;
- 1.062883-second median and 1.139437-second p95 for dispatch decisions;
- 1.008864-second median and 1.053451-second p95 for status decisions; and
- zero turns above three seconds.

The final disposition includes deterministic reconciliation for only
unambiguous transcript forms: explicit status/cancel phrases, direct
imperatives beginning with the frozen action vocabulary, informational
question forms, and explicit hypothetical language. Everything else retains
the model result and still passes through the shared Coordinator policy. This
made clear intent non-probabilistic without creating a trigger phrase.

Dynamic utterance identity is bound locally to the originating URLSession task
rather than trusted to model text. The model-provided UUID remains part of the
strict schema for diagnostics, but cannot redirect a result to another
utterance. This preserves stale-result rejection at the Coordinator admission
boundary without making a probabilistic UUID echo the transport authority.

## oMLX state and cache findings

Unbounded `previous_response_id` continuity failed both latency and
correctness. With cache disabled, the 4B model rose from 1.064 seconds on turn
one to 4.357 seconds by turn 25 as the complete prior conversation was
re-prefilled. With the configured tiered cache enabled, the third chained
0.6B turn logged a cache hit, failed to restore the referenced block, reported
failed paged-cache reconstruction, and then made no generation progress until
the client disconnected 55 seconds later.

Short two- and four-turn chains reduced the latency growth but still caused
occasional prior-UUID echoes. Slice One therefore uses the Responses endpoint
without stored cross-turn state: `store` is false and
`previous_response_id` is absent. The narrow Interactor sees the current
committed transcript; authoritative conversation, job, and proposal state
remains in the native Coordinator. This is both faster and safer for the
actual boundary while preserving the user-selected Responses API.
