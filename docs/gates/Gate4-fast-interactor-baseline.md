# Gate 4: fast Interactor baseline

Status: **live Coordinator path and Moshi chat-completions boundary compiled;
MLX invocation, injection, and latency corpus pending**

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

The executed unit target now includes a real URLSession request across this
loopback boundary in addition to direct adapter coverage. This proves the
native HTTP and Coordinator seam, but it does not claim that the current MLX
runner consumes or injects the returned ARC condition.

## Remaining Gate 4 work

- Connect committed local ASR text to this boundary in the packaged MLX
  runtime.
- Apply the adapter result through the ARC encoder and fuse its streaming-sum
  condition into each MLX Moshi step.
- Run the frozen fidelity and latency corpora and publish measured native
  overhead plus remaining model allowances.
- Freeze the observed Interaction-miss wording policy.
