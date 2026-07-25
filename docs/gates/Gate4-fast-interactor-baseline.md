# Gate 4: fast Interactor baseline

Status: **Coordinator admission and grounded-acknowledgement boundary compiled;
live Moshi injection and latency corpus pending**

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

Xcode `build-for-testing` compiles focused fixtures proving:

- a valid start request reaches Pi before the grounded project-naming
  Reference is delivered;
- a stale transcript revision is rejected before a second Interactor call; and
- a status request paired with a start receipt publishes no Reference.

## Remaining Gate 4 work

- Adapt Pi RPC through one Coordinator-owned serialized job controller shared
  by voice and the typed Pi Console.
- Expose the OpenAI-compatible chat-completions adapter Moshi-RAG expects.
- Reconcile eager Interaction results with Moshi `<ret>` requests.
- Run the frozen fidelity and latency corpora and publish measured native
  overhead plus remaining model allowances.
- Freeze the observed Interaction-miss wording policy.
