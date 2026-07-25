# Gate 4: fast Interactor baseline

Status: **Coordinator admission, grounded acknowledgement, and serialized Pi
job controller compiled; live Moshi injection and latency corpus pending**

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

## Remaining Gate 4 work

- Inject the existing shared `PiJobController` into the live
  `ConversationCoordinator` voice path.
- Expose the OpenAI-compatible chat-completions adapter Moshi-RAG expects.
- Reconcile eager Interaction results with Moshi `<ret>` requests.
- Run the frozen fidelity and latency corpora and publish measured native
  overhead plus remaining model allowances.
- Freeze the observed Interaction-miss wording policy.
