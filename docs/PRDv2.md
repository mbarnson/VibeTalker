# VibeTalker Slice One PRD

## Product Promise

From one native macOS app and one configured sandbox project, the developer can
converse naturally with Moshi, ask for a coding task without a trigger phrase,
keep talking while pi works, ask what it is doing and receive a grounded
answer, and hear when the work finishes.

Slice One is complete when that narrow loop is useful and enjoyable as-is. It
is not a partial implementation of the larger architecture. The original,
broader PRD remains architectural context in Git history, but features outside
this promise do not belong in Slice One.

## Slice One Success Criteria

The acceptance configuration is a warmed system on the target M4 Max. Cold
model loading and model downloads are measured separately. Latency percentiles
are calculated over a frozen 100-turn warmed corpus containing 60 ordinary
conversation turns, 20 dispatch turns, and 20 status turns. Reference latency
uses all 100 turns; acknowledgement and status percentiles each use their
corresponding 20-turn subset. The first 10 dispatch turns reuse the direct
requests from the intent corpus; all other latency turns are distinct. Initial
numbers are product targets to validate, not claims that the unproven
architecture already meets them.

- Median speech-endpoint-to-committed-job-acknowledgement is at most 1.5
  seconds; p95 is at most 2.5 seconds. The acknowledgement occurs only after
  the Pi Request is validated and names the selected project.
- P95 speech-endpoint-to-Reference-injection is at most 2 seconds. At most one
  of the 100 measured turns may exceed 3 seconds.
- P95 spoken-status-request-to-first-audible-answer is at most 2 seconds.
- Pi completion appears in the Pi Console within 500 milliseconds and produces
  a spoken completion within 2.5 seconds at p95.
- A ten-minute full-duplex session remains free of audible underruns or
  conversation stalls while pi performs a representative coding task.
- A frozen 40-turn intent corpus contains 10 direct coding requests, 10
  ordinary conversational turns, 10 quoted or hypothetical requests, and 10
  ambiguous, destructive, external, or project-changing requests. Every direct
  request dispatches to the correct sandbox; the other 30 produce zero
  automatic dispatches. Confirmable in-sandbox requests in the final 10 require
  confirmation, while external and project-changing requests are explicitly
  refused as unavailable in Slice One.
- Status answers never claim a changed file, passing test, or completed phase
  without corresponding pi or repository evidence.
- At least 16 of a frozen 20-turn conversation corpus are rated natural and
  useful under a rubric written before evaluation; no scripted or freeform turn
  may cause an unauthorized action.
- Interactor timeout, provider failure, and invalid output never stall Moshi,
  dispatch pi, or sound like affirmative job acceptance. The miss is visible in
  the Pi Console. Gate 4 selects failure language that remains natural during
  ordinary conversation while preserving the project-naming acknowledgement as
  the only voice signal that work started.
- One spoken request completes a harmless sandbox edit, verification, grounded
  status exchange, and proactive completion from end to end.
- A task typed into the Pi Console composer while pi is idle dispatches through
  the same policy, validation, and acknowledgement rules as a spoken request. A
  typed abort cancels the active job with visible confirmation. While a job is
  running, the composer accepts only abort; other typed input is visibly
  declined rather than silently queued or reinterpreted.
- Attempts by pi to write outside its workspace through an exposed file or
  command tool fail. App Sandbox independently prevents the app, pi, and
  inherited children from writing to unrelated host locations outside
  VibeTalker's container and sandbox-provided ephemeral storage. Attempts by a
  pi-launched command to initiate an outbound network connection also fail, and
  a spoken confirmation does not widen any capability.
- After prerequisites and model downloads exist, a fresh checkout reaches its
  first conversation within ten minutes by following the documented first-run
  path.

## Go/No-Go Experiments

Implementation proceeds through the following gates in order. A failed gate
stops dependent work until the product promise or architecture is deliberately
changed.

0. **Native platform preflight:** Before product integration, build a minimal
   signed and sandboxed Xcode app that launches a signed Node helper and
   exchanges one message with it over stdio. Prove the Node helper under
   Hardened Runtime with `com.apple.security.cs.allow-jit`, record a
   `--jitless` comparison, and prove that the nested `sandbox-exec` profile
   denies an outside-workspace write and an outbound network connection using
   escape fixtures run from within the sandboxed app. Record the macOS, Xcode,
   and Node revisions. Any unsolved failure blocks native integration; there is
   no unsandboxed fallback.
1. **Upstream Moshi-RAG baseline:** Run the unmodified Rust/Candle Metal
   backend with local STT and prove microphone input, streaming ASR,
   full-duplex speech, barge-in, `<ret>`, Reference conditioning, and browser
   reconnection. Record whether the Rust standalone embeds the ARC Reference
   Encoder or requires the separate conditioner service used by the Python
   topology; that result determines what the native app supervises and what
   startup diagnostics probe.
2. **Reference fidelity:** Manually inject canned References through Moshi's
   existing conditioning seam in two independent 10-turn runs. Each run must
   produce at least 8 fully correct turns, the aggregate must produce at least
   17 of 20, and no turn may directly contradict the injected Reference. The
   aggregate requirement deliberately means at least one run must reach 9 of
   10, preventing two minimally passing runs from satisfying the gate. The
   corpus and scoring rubric are frozen before either run. Failure invalidates
   Moshi-as-speech-interface for this design.
3. **Proactive completion:** Inject an externally initiated completion message
   and prove that Moshi speaks it naturally and promptly without a new user
   utterance. This is a Slice One requirement, not a deferred enhancement. If
   Moshi cannot do it, choose an alternate narrow speech-delivery path or
   explicitly revise the product promise before continuing.
4. **Fast-Interactor voice loop:** Connect the Coordinator to a deterministic
   or lightweight Responses backend and meet the acknowledgement and Reference
   latency targets before involving pi or Laguna. The committed acknowledgement
   measurement includes the complete Interaction round trip and Pi Request
   validation; no speculative receipt counts toward the target. Record the
   endpointing, Coordinator, transport, validation, and Moshi-injection
   machinery overhead, then publish the remaining median and p95 Interaction
   model allowances derived from the product SLOs. The gate also compares a
   neutral conversational miss against a cheap deterministic action-likeness
   heuristic that adds explicit "no work started" language only to likely
   action turns. Freeze the less disruptive safe policy from observed use
   rather than assuming every miss should speak the same disclaimer.
5. **Sandboxed native pi loop:** Build and sign the Xcode app, launch its
   embedded pi helper, and dispatch one natural spoken request into the
   app-container workspace. Keep Moshi responsive, answer a grounded status
   question, close and reopen the Pi Console view and app window without
   affecting the job, and report completion. Before passing, prove separately
   that pi file and command tools cannot write outside the workspace, App
   Sandbox prevents writes to tested unrelated host locations, pi-launched
   commands cannot initiate outbound network connections, and the helper
   receives no unrelated host credentials.
6. **Local-model coexistence:** Record two independent results before selecting
   the release model:
   - **Memory coexistence:** Load Moshi-RAG and Laguna together and measure
     steady-state memory pressure, caches, swap, and audio health.
   - **Shared-model contention:** Run concurrent Interaction and pi requests
     through oMLX and measure admission delay, Reference latency, tokens per
     second, and audio quality.
   A failure in one dimension is not reported as evidence about the other.

## Problem Statement

Voice interfaces to coding models tend to collapse two different jobs into one
synchronous loop: maintaining a natural, interruptible conversation and
performing long-running, stateful development work. When one agent owns both,
the conversation stalls while coding or the voice application must recreate a
coding harness, tools, provider integrations, sessions, and delegation.

Audex-Mac demonstrated that a local speech interface becomes substantially
more useful when a knowledgeable model supplies the substance of the
conversation. Rebuilding the complete development-agent toolchain behind
Audex-Mac would duplicate work already performed well by pi.

Moshi-RAG is a promising voice front end because it remains full-duplex while
an asynchronous text backend supplies Reference context. On its own, however,
Moshi has limited world knowledge, relies on a probabilistic learned `<ret>`
token to request help, and is not a coding harness. The developer needs stronger
knowledge on ordinary turns and natural coding delegation without granting
ambient speech direct filesystem or shell authority.

Pi intentionally has no built-in permission system or execution sandbox; it
runs with the authority of its launching process. Treating pi approval as a
security boundary would therefore expose the developer's Mac to transcription
mistakes, model mistakes, prompt injection, and ordinary agent error. Slice One
needs a real operating-system boundary while retaining pi's model loop and
provider integrations.

The product must also be diagnosable. A poor voice turn may originate in
endpointing, ASR, stale transcript state, Interaction latency, Reference
conditioning, Moshi, or pi. Slice One needs enough correlated evidence to find
that boundary without first building a distributed tracing platform.

## Solution

VibeTalker connects five deliberately narrow runtime roles:

- The **Native Host** is a directly distributed macOS app built as an Xcode
  project. Swift and SwiftUI own lifecycle, configuration, permission status
  and guidance, the split conversation-and-console layout, lightweight health
  and run controls, process supervision, and the Coordinator boundary.
- The **Voice Front End** uses Moshi-RAG for microphone input, streaming ASR,
  semantic turn-taking, full-duplex speech, barge-in, and Reference
  conditioning.
- The **Coordinator** owns transcript truth, eager Reference scheduling,
  project and action policy, lifecycle state, pi RPC, and a small correlated
  event ledger.
- The **Interactor** is the stateful Responses client around the configured
  Interaction Model. It returns one short Reference Response for Moshi and,
  when the user clearly requests coding work, one optional Pi Request phrased
  as the instruction the user would have typed to pi.
- The **Coding Agent** is pi. It owns coding models, tool invocation, file
  mutation, shell commands, tests, provider routing, and sessions. It does not
  supply VibeTalker's permission boundary.

The primary flow is:

`user audio ↔ Moshi-RAG`

`committed transcript → Coordinator → Interactor`

`Reference Response → Coordinator → Moshi-RAG`

`accepted Pi Request → Coordinator → pi RPC`

`pi events → Coordinator → Pi Console and later Interactor context`

`typed composer input → Pi Console → Coordinator → the same pi RPC session`

The Coordinator requests Interaction eagerly at a stable transcript boundary;
the user does not need a wake word or dispatch phrase, and Moshi does not need
to emit `<ret>` first. Moshi's learned token remains an opportunistic refresh
signal. It never authorizes an action.

Ordinary conversation produces only a Reference Response. A clear coding
request may additionally produce one Pi Request. The Coordinator accepts only
an unambiguous request within the already selected sandbox project. Ambiguous
or destructive in-sandbox requests require natural confirmation. External and
project-changing requests are refused in Slice One even after confirmation.

The Native Host is signed with Developer ID, uses Hardened Runtime and App
Sandbox, and stores the Slice One coding project inside its own app container.
The embedded pi helper inherits that sandbox, preventing writes elsewhere on
the Mac. VibeTalker installs a narrow pi tool-policy extension that constrains
pi file tools to the workspace and runs shell commands inside an additional
fixed `sandbox-exec` profile with outbound networking denied and the same
workspace rule. The app may still write its own configuration, runtime state,
and Event Ledger elsewhere in its container. The helper receives a minimal
environment without unrelated host credentials. Confirmation changes
Coordinator intent state; it never expands an operating-system capability.

The app window is split horizontally. The left SwiftUI surface presents the
committed conversation, References, voice connection state, and backend health
while the upstream Moshi browser continues to own microphone capture. The
right surface is the **Pi Console**: a native, in-process, monospaced,
append-only SwiftUI view rendering the same ordered, lossless Event Ledger
projection as the external observer CLI, styled by event kind, with a single
composer line. No terminal emulator, PTY, child console process, shell, or
second pi instance exists; the console is the pretty-printer moved indoors,
plus one explicit typed control channel.

Typed composer input is deliberate user control, not ambient speech. It
bypasses conversational intent classification because it is explicit typed
input, but it does not bypass project, risk, or capability policy. When pi is
idle, a submitted instruction becomes a normal Pi Request through the same
validation and acknowledgement path as voice. While a job runs, the composer
accepts only an explicit abort; other typed input is visibly declined with
guidance rather than queued or reinterpreted. Steering an active job is the
first planned post-slice increment, not Slice One scope.

The Coordinator serializes typed and mediated inputs into one per-job command
stream. A typed operation accepted before a mediated request dispatches
invalidates that pending request; once an RPC operation is dispatched, ledger
order is authoritative. Every operation records its origin, and the Interactor
receives the resulting event snapshot on later turns. Typed input never
creates, attaches to, or silently switches to another pi session.

The Interactor stays responsive while pi works. It can answer ordinary
questions and grounded status questions from a compact Coordinator snapshot.
Pi's event stream supplies the evidence; the Interactor does not receive pi's
coding tools and does not become another agent harness.

If the Interactor times out, fails, or returns invalid output, Moshi remains
responsive and pi receives nothing. The Coordinator records the miss. Gate 4
chooses empirically between a neutral conversational failure Reference and a
deterministic action-likeness heuristic that reserves explicit "no work
started" language for likely action turns. In either policy, only a
project-naming committed acknowledgement means that pi started.

The Pi Console pretty-prints committed ASR, Reference Responses, Pi Requests,
typed console operations, policy decisions, Moshi conditioning milestones, pi
lifecycle events, errors, and completion. It is the complete Slice One
activity surface as well as the explicit manual control channel. A read-only
`vibetalker observe --follow` CLI renders the same projection for developers
who prefer an external terminal, including cmux, without VibeTalker launching
or controlling that terminal.

Completion is both visual and spoken. Pi completion enters the event ledger
immediately, and the Coordinator injects a short completion Reference so the
developer receives the payoff without remembering to ask.

## User Stories

1. As a developer, I want a documented path from checkout to first
   conversation, so that VibeTalker feels like a usable product rather than a
   collection of experiments.
2. As a developer, I want startup diagnostics to identify missing models,
   services, permissions, and configuration, so that setup failures are
   actionable.
3. As a developer, I want one native macOS app to launch the voice session and
   present its Pi Console, so that the complete product starts predictably.
4. As a developer, I want to converse naturally with Moshi, so that the
   interface remains useful when I am not requesting code.
5. As a developer, I want a knowledgeable local Interactor to augment ordinary
   turns, so that conversation is more factual and stimulating than Moshi
   alone.
6. As a developer, I want to request coding work in ordinary language, so that
   I do not memorize a wake word or dispatch phrase.
7. As a developer, I want casual, quoted, and hypothetical discussion to remain
   conversation, so that ambient speech does not start jobs.
8. As a developer, I want an immediate spoken acknowledgement when a job is
   accepted, so that the voice loop never waits for coding to finish.
9. As a developer, I want the acknowledgement to name the selected project, so
   that I can catch an incorrect mutation boundary immediately.
10. As a developer, I want pi to work asynchronously, so that I can continue
    talking while it edits and tests.
11. As a developer, I want to ask what pi is doing and receive an evidence-based
    answer, so that I can follow progress without reading raw tool output.
12. As a developer, I want uncertain or incomplete progress described
    honestly, so that the Interactor does not invent activity.
13. As a developer, I want to cancel an active job by voice and receive
    confirmation, so that obsolete work stops visibly.
14. As a developer, I want to hear when pi finishes, so that the asynchronous
    loop has a satisfying and unmistakable payoff.
15. As a developer, I want completion to state changed files, verification, and
    remaining problems, so that I know what was accomplished.
16. As a developer, I want completion and failure visible in the Pi Console, so
    that spoken delivery is not the only evidence.
17. As a developer, I want Moshi to remain responsive when the Interactor
    fails, so that a knowledge-backend problem never makes the voice product
    feel mute or falsely starts work.
18. As a developer, I want barge-in to keep working during acknowledgements and
    completion, so that system speech never traps the conversation.
19. As a developer, I want routine pi activity to remain in the Pi Console
    unless I ask about it, so that progress narration does not monopolize the
    voice channel.
20. As a developer, I want critical confirmation, failure, cancellation, and
    completion events prioritized, so that important state is not buried.
21. As a developer, I want the Interactor unable to edit files or run arbitrary
    commands, so that transcription mistakes cannot directly mutate my Mac.
22. As a developer, I want pi to retain its coding loop, tools, models,
    sessions, and provider routing behind VibeTalker's security boundary, so
    that VibeTalker does not replace my coding harness.
23. As a developer, I want macOS to prevent writes outside VibeTalker's
    container and Pi's exposed tools to be restricted further to the workspace,
    so that the first release cannot modify unrelated work even when a model or
    tool misbehaves.
24. As a developer, I want destructive in-project actions confirmed and
    external or project-changing actions unavailable, so that voice initiation
    cannot broaden the app's authority.
25. As a developer, I want one active mutating job, so that cancellation,
    status, and file ownership remain unambiguous.
26. As a developer, I want the pi session to retain project context across
    later requests, so that I do not restate the project history.
27. As a developer, I want the voice conversation and pi session to have
    separate context, so that conversational chatter does not consume the
    coding agent's working context.
28. As a developer, I want the Pi Console to show exactly what committed ASR,
    Reference, Pi Request, and typed instruction crossed each boundary, so that
    I can diagnose mistranscription and model mediation.
29. As a developer, I want console events correlated by voice turn, input
    origin, and pi job, so that asynchronous activity remains causally
    understandable.
30. As a developer, I want secrets redacted before console publication or
    spoken delivery, so that useful diagnostics do not disclose credentials.
31. As a developer, I want console rendering to stay off the audio hot path,
    so that measuring the conversation does not degrade it.
32. As a developer, I want closing or reconnecting the browser, console view,
    or app window to leave pi running, so that presentation lifecycle does not
    become job lifecycle.
33. As a developer, I want local reasoning, local speech recognition, and any
    configured cloud use shown clearly at startup, so that the privacy boundary
    is never implicit.
34. As a developer, I want Interaction and pi latency measured independently,
    so that shared-model contention is visible during local experiments.
35. As a developer, I want the complete first release proven in a harmless
    app-container sandbox, so that integration defects cannot damage active
    work.
36. As a developer, I want setup, permissions, backend locality, lifecycle, and
    health presented with lightweight native controls, so that routine
    operation feels like a Mac app alongside the Pi Console.
37. As a developer, I want the live pi session visible in a monospaced,
    scrollable, searchable, copyable console, so that I can inspect its work
    with familiar terminal-like readability.
38. As a developer, I want to type a task into the console while pi is idle,
    so that I can dispatch work by keyboard through the same policy path as
    voice.
39. As a developer, I want to type an abort into the console while pi is
    running, so that I can stop unwanted work without reaching for the voice
    channel.
40. As a developer, I want the console to redisplay recent history and current
    job state after its view or the app window reopens, so that a presentation
    failure never strands or duplicates the coding agent.

## Implementation Decisions

- Slice One implements only the Product Promise. Work stops at failed
  Go/No-Go gates rather than scaffolding dependent features speculatively.
- VibeTalker is an Xcode macOS application written in Swift. SwiftUI supplies a
  horizontally split conversation-and-console surface; Swift concurrency and
  native process APIs own lifecycle, supervision, Coordinator state, and Event
  Ledger publication.
- The app is distributed directly with Developer ID signing, Hardened Runtime,
  and App Sandbox enabled. Mac App Store distribution is not a Slice One goal.
- The app target declares outbound network-client access for configured model
  and speech services and incoming network-server access for the loopback
  Coordinator adapter. It declares no user-selected-file access in Slice One.
  The upstream Moshi browser remains the audio-capture surface and owns
  microphone permission; the native app launches it and reports its connection
  and audio health rather than replacing it with a new voice UI.
- The Pi Console is a native, in-process SwiftUI view, not a terminal emulator.
  It renders the Event Ledger and normalized pi text and tool activity as a
  monospaced, append-only log with kind-based coloring, scrollback, selection,
  copy, search, and pause-follow, plus one composer line. It has no PTY, no
  child console process, no shell, no filtering UI, no panes, no persistence
  beyond the ledger itself, and no interaction that mutates Coordinator state
  except the composer's validated prompt and abort operations.
- The Slice One workspace is created inside the app container. Arbitrary
  user-selected projects are deferred so the writable-root guarantee depends on
  static sandbox rights rather than fragile propagation of a dynamically
  granted folder.
- Moshi-RAG remains the Voice Front End. Its upstream Rust/Candle Metal runtime
  must pass an unmodified baseline before integration patches are introduced.
- Slice One uses local STT by default. Gradium or any other hosted STT is an
  explicit opt-in because microphone-derived audio leaves the Mac; startup and
  diagnostics disclose speech, Interaction, and coding backends independently
  as local or hosted.
- Gate 1 records whether the accepted Rust/Metal Moshi-RAG build embeds the ARC
  Reference Encoder or depends on a separately supervised conditioner process.
  The app supervises and diagnostics probe the topology actually proven by the
  gate.
- The Coordinator consumes the user and model text frames Moshi already emits
  and maintains one canonical Transcript Ledger. It does not run a second ASR
  stack.
- A semantic endpoint detector commits coherent user turns. VAD silence is
  evidence, not the sole definition of a completed thought.
- The Coordinator requests a Reference eagerly for every committed coherent
  turn. Moshi's `<ret>` request is reconciled against the same utterance and may
  refresh or reuse the eager result.
- Reference scheduling retains only the minimum identities required to reject
  stale results: voice session, utterance, transcript revision, Interaction
  request, creation time, and disposition.
- The Coordinator exposes the OpenAI-compatible chat-completions adapter
  Moshi-RAG expects. This adapter resolves Reference requests; it never invokes
  pi.
- Slice One configures the Coordinator as Moshi-RAG's only retrieval profile.
  Upstream multi-profile configuration is not used as a silent fallback to
  another knowledge backend.
- The Interactor calls the configured OpenAI or oMLX `/v1/responses` endpoint
  directly. Pi is not placed in the latency-critical conversation path.
- The Interactor retains one stateful Responses conversation and chains turns
  with `previous_response_id` when the provider supports stored state. It
  resends developer instructions on every request.
- The inspected daily oMLX checkout already implements `/v1/responses` and
  persisted `previous_response_id` chaining. Release diagnostics require the
  endpoint, structured output behavior, and stored-state behavior expected by
  VibeTalker. Missing capability is an incompatible configuration, not a silent
  fallback to a different protocol or client-managed transcript.
- The validated Interaction result contains one utterance identity, one short
  Reference Response, and at most one optional Pi Request. Partial or malformed
  results affect neither Moshi nor pi.
- Interactor timeout, provider failure, cancellation, or invalid output never
  blocks Moshi and never dispatches pi. The Coordinator publishes an
  Interaction-miss event. Gate 4 freezes either a neutral conversational miss
  Reference or a deterministic action-likeness heuristic that adds explicit
  non-dispatch language only to likely action turns. The heuristic may affect
  wording but cannot authorize or dispatch work.
- The Interactor has no pi tool definitions, shell, file-write, or arbitrary
  command capability. Any project observations supplied to it are bounded
  reads, Git status/diff, and compact pi evidence selected by the Coordinator.
- A Pi Request expresses one operation: start, cancel, or request status. The
  Coordinator validates project, job identity, ambiguity, and risk before
  translating it into pi RPC.
- A typed Pi Console operation expresses prompt or abort and carries console,
  session, command, and job identities. It bypasses conversational intent
  classification because it is explicit typed user input, but it does not
  bypass project, risk, or capability policy. While a job is running, only
  abort is accepted; other typed input is declined with visible guidance.
  Destructive typed in-workspace instructions still require confirmation in the
  console, and external or project-changing instructions remain unavailable.
- Direct, unambiguous work inside the selected sandbox may start immediately.
  Ambiguous or destructive in-sandbox proposals remain pending until naturally
  confirmed. External and project-changing proposals are rejected as
  unavailable in Slice One; confirmation cannot promote them.
- A pending proposal carries a proposal identity, normalized action, project,
  risk reason, and expiry. Its confirmation question is delivered through the
  Reference Response. The next committed utterance may confirm or reject that
  proposal; any committed utterance that does not address it expires it. A
  proposal also expires after 30 seconds, when replaced by another proposal, or
  when the project or voice session changes. Confirmation must correlate to the
  live proposal identity, and every expiry is an Event Ledger entry.
- A committed job acknowledgement is generated only after the Pi Request and
  project are validated. It names the sandbox and therefore measures the same
  round trip as Interaction decision latency; speculative verbal receipt does
  not satisfy the acknowledgement SLO.
- Pi is the sole Coding Agent. VibeTalker uses pi's supported RPC or SDK
  interface and does not reimplement its model loop, tools, providers,
  compaction, or session storage.
- Pi and its compatible runtime are packaged at a pinned revision inside the
  app rather than launched from an ambient user installation. The executable
  helper is signed to inherit the parent app's sandbox and starts in the
  app-container workspace with a minimal environment. Pi may retain explicitly
  configured provider credentials, but unrelated host credentials and
  credential-bearing environment variables are absent.
- The Node executable is signed for Hardened Runtime with the narrow
  `com.apple.security.cs.allow-jit` exception if Gate 0 proves it reliable on
  the target macOS release. Gate 0 also records `--jitless` behavior as the
  preferred fallback. VibeTalker does not add unsigned-executable-memory,
  disabled-library-validation, or broader runtime exceptions to make Node
  launch.
- VibeTalker starts pi without ambient user or project extensions and loads only
  its pinned tool-policy extension. That extension overrides every exposed
  built-in file, search, and command tool. File mutations resolve and validate
  canonical paths beneath the workspace before execution.
- After pi initializes, VibeTalker enumerates the registered tool surface and
  hard-fails the session if any tool is absent from the pinned override
  manifest or if an expected override is inactive. A pi revision cannot add a
  newly privileged tool silently.
- The tool-policy extension runs commands with a fixed `sandbox-exec` profile.
  Commands may read the workspace and required system/toolchain resources, may
  write only the workspace and explicit ephemeral runtime locations, and may
  not initiate network connections. Their environment is independently
  allow-listed and excludes model-provider credentials and unrelated host
  secrets. There is no general escape hatch in Slice One.
- App Sandbox is the final operating-system write boundary outside
  VibeTalker's container for pi and all inherited children. The narrower
  workspace checks and command profile protect the app's own configuration,
  runtime state, and Event Ledger from Pi tools inside that container.
- The Native Host may use its network-client entitlement for configured Moshi,
  Interactor, oMLX, and pi provider traffic. That entitlement is not treated as
  a destination-restricted Pi tool permission; tool commands remain inside the
  network-denied nested profile.
- The pi process necessarily retains network access to its explicitly selected
  provider. A hosted provider can therefore receive workspace material included
  in pi inference context even though pi-launched commands cannot open network
  connections. Startup discloses this provider-channel egress; an all-local
  oMLX coding backend avoids it. Slice One does not claim to broker or inspect
  model-provider egress.
- Slice One permits one active mutating Action Job. Its states are proposed,
  waiting-for-confirmation, accepted, running, cancelling, completed, failed,
  and cancelled.
- Conversational corrections are not automatically reinterpreted as active-job
  steering. Both voice and typed changes to a running job use
  cancel-and-redispatch in Slice One; typed steering through pi RPC `steer` is
  the first planned post-slice increment. A request after completion, spoken or
  typed, is a new dispatch in the retained pi session.
- Pi Console operations and Interactor Pi Requests enter one Coordinator-owned
  serial command stream. A typed operation accepted before a mediated request
  is dispatched invalidates that pending request. Once an RPC operation is
  accepted, ledger order is authoritative; VibeTalker does not pretend to
  retract a tool call already running.
- Pi text and structured tool, file, test, error, and completion
  events are normalized into a compact job snapshot. The Interactor receives
  this evidence on later status turns.
- Status answers must cite Coordinator or repository evidence internally and
  state uncertainty when the evidence is incomplete.
- Routine pi progress remains Pi-Console-only. Spoken progress occurs when the
  user asks; confirmation, failure, cancellation, and completion may interrupt
  according to voice priority policy.
- Proactive completion is part of Slice One. The Coordinator turns a pi
  completion event into a short Reference containing result, changed files,
  verification, and unresolved problems, then triggers the proven speech path.
- The release configuration supports a local oMLX Interactor. Pi's provider
  remains pi configuration and may independently use oMLX or another explicit
  backend.
- Shared oMLX use is an optimization to validate, not a prerequisite baked into
  component boundaries. The Interactor and pi always retain separate sessions.
- The first-run surface consists of the native app, one configuration,
  lightweight SwiftUI setup and diagnostics, the equivalent
  `vibetalker doctor` and `vibetalker start` commands, and a bundled sandbox
  task. Diagnostics check code signing and effective entitlements, model and
  STT locality, oMLX Responses compatibility, Moshi topology, pi RPC,
  microphone permission, Node JIT mode, registered pi tools, app-container
  workspace, command sandbox, ports, and memory and disk headroom.
- Moshi-RAG weights and any separately required Reference Encoder or local STT
  weights live in managed app-container storage because Slice One declares no
  user-selected-file entitlement. First-run diagnostics calculate and disclose
  the additional disk requirement; an existing Hugging Face cache is not
  assumed to be reusable and may be duplicated.
- Startup identifies every configured speech, Interaction, and coding backend
  as local or hosted before audio is accepted. There is no silent cloud
  fallback.
- The app-container sandbox project is the only writable project root exposed
  to pi in Slice One. The app retains separate writable configuration, runtime,
  and Event Ledger locations inside its container. Global pi configuration, pi
  source, Moshi-RAG source, VibeTalker itself, and unrelated projects remain
  protected.
- The Slice One Event Ledger is append-only JSONL with a small versioned
  envelope: event identity, monotonic and wall timestamp, source, kind, voice
  session, utterance and revision when relevant, Interaction request when
  relevant, Action Job when relevant, and redacted payload.
- Required ledger events are committed ASR, Interaction request, validated
  Reference, validated Pi Request, typed console prompt and abort, Coordinator
  policy decision, console command acceptance and rejection, Reference
  accepted/failed by Moshi, Interaction miss, proposal creation and expiry,
  first output audio, pi lifecycle and verification, error, cancellation, and
  completion.
- Event publication uses a bounded non-blocking channel. High-volume partials
  and token/audio activity are not durably recorded. If the ledger cannot keep
  up, it publishes a dropped-event count without blocking audio or generation.
- `vibetalker observe --follow` is a terminal-neutral pretty-printer following
  the JSONL ledger. It supports bounded recent history followed by live events;
  it is not a state store, process supervisor, job owner, or interactive pi
  client.
- The Pi Console renders the same ordered, lossless ledger projection as the
  external observer CLI, with styling added by event kind. The console is a
  replaceable subscriber and control surface. Closing the browser, console
  view, or app window does not terminate the Coordinator, pi session, or
  active job. Reattachment receives current voice state, job state, and
  bounded recent history before following live events.
- Credentials, configured secrets, and credential-shaped values are redacted
  before ledger publication, Interactor context, or Moshi Reference delivery.
  Hidden model reasoning and raw audio are never ledger content.

## Testing Decisions

- The highest automated seam is the complete Coordinator boundary. Fake Moshi,
  Responses, pi, and Pi Console adapters send deterministic protocol streams
  through the real Coordinator, and tests assert externally visible References,
  policy, pi operations, input arbitration, job state, JSONL events, and
  completion.
- Tests verify behavior, timing boundaries, and capability enforcement rather
  than private functions or exact prompt wording.
- Each Go/No-Go experiment produces a small reproducible fixture, measurement,
  and pass/fail record before dependent implementation begins. Gate 0 retains
  the signed minimal app and escape fixtures as a permanent platform test
  target.
- Moshi adapter contract tests cover committed transcript delivery, `<ret>`
  reconciliation, Reference acceptance/failure, first output audio, barge-in,
  timeout, and reconnect.
- Responses contract tests cover OpenAI and oMLX typed streaming events,
  completed/error outcomes, strict Interaction result validation,
  `previous_response_id`, cancellation, missing stored state, timeout, malformed
  output, and deterministic graceful degradation without pi dispatch.
- Pi contract tests cover RPC framing, prompt acceptance, event correlation,
  status, abort, completion, and process exit. A framing fixture includes valid
  JSON strings containing U+2028 and U+2029 and proves that only LF terminates a
  pi RPC JSONL record.
- Pi Console contract tests prove that the composer submits prompt and abort
  with stable identities through the same Coordinator policy path as voice,
  that prompt is accepted only while pi is idle and abort only while a job is
  active, that other running-state input is visibly declined, and that the
  console cannot address or create another pi session.
- A shared ledger fixture is rendered through the Pi Console and
  `vibetalker observe --follow`. After styling is removed, both projections
  contain the same ordered events and lossless fields.
- Input-arbitration tests race an Interactor Pi Request, a typed prompt, a
  typed and spoken abort, pi tool activity, and completion. They assert
  explicit ledger order, typed priority only before dispatch, and no false
  claim that an already-running tool call was retracted.
- Intent tests use the frozen 40-turn corpus: 10 direct coding requests, 10
  ordinary conversational turns, 10 quoted or hypothetical requests, and 10
  ambiguous or risky requests. All direct requests must dispatch to the
  sandbox; the other 30 must not dispatch. Confirmable in-sandbox requests in
  the final 10 must require confirmation, while external and project-changing
  requests must be refused as unavailable.
- Policy and project-boundary tests prove that only clear work in the selected
  sandbox may start directly, riskier in-sandbox proposals remain pending, and
  external or project-changing proposals cannot be promoted by confirmation,
  whether spoken or typed.
- Pending-proposal tests prove that the confirmation question carries the live
  proposal, only the immediately responsive utterance can confirm it, unrelated
  speech and the 30-second timeout expire it, replacement and session/project
  changes invalidate it, stale "yes" cannot dispatch, and expiry is visible in
  JSONL.
- Capability tests prove that the Interactor and Moshi cannot acquire shell,
  write, mutation, or pi coding tools through any exposed interface, and that
  the Pi Console exposes no shell, process-execution, or file surface beyond
  its validated prompt and abort operations.
- Tool-manifest tests inject an unknown registered pi tool and remove one
  expected override. Both conditions must hard-fail startup before the model
  receives a prompt.
- Signed-build capability tests inspect the effective app and helper
  entitlements, prove that the embedded pi helper inherits App Sandbox, and
  verify that the app, pi, and inherited child processes cannot write to tested
  unrelated host locations outside the VibeTalker container and
  sandbox-provided ephemeral storage.
- Command-sandbox tests run harmless write and network escape fixtures through
  the same pi file and command seams used in production. File tools and commands
  must reject outside-workspace mutations, commands must reject outbound
  connections, confirmation must not alter either result, and unrelated
  synthetic credentials must be absent from the helper environment.
- Transcript and Reference tests race corrected ASR, barge-in, eager
  Interaction, `<ret>`, timeout, and a later utterance. Only the freshest valid
  Reference may reach Moshi.
- Grounding tests prove that status and completion omit or qualify any changed
  file, test result, or phase lacking corresponding evidence.
- Redaction tests place synthetic secrets in transcript, diff, pi output,
  failure, and environment-shaped data and assert that neither JSONL nor speech
  exposes them.
- Event-ledger tests assert the small schema, causal identifiers, append-only
  ordering, recent-history follow behavior, malformed-event handling, and
  explicit dropped-event reporting.
- Backpressure tests saturate event publication and prove that voice and pi
  continue while telemetry loss becomes visible.
- First-run tests begin from a clean configuration, exercise diagnostics,
  reject missing prerequisites clearly, grant microphone access through the
  Moshi browser launched by the native app, disclose every local or hosted
  backend and provider-egress boundary, start the system, present the Pi
  Console, and complete the bundled sandbox task.
- The vertical-slice acceptance test speaks a natural request, hears an
  acknowledgement naming the sandbox, continues ordinary conversation, asks
  for grounded status, observes the edit and verification, and hears proactive
  completion.
- A composer acceptance test types a task while pi is idle and observes the
  same validation, acknowledgement, and dispatch behavior as voice; types
  non-abort input during the run and observes the visible decline; then types
  an abort and observes correlated cancellation.
- A degradation acceptance test injects timeout, provider error, and malformed
  Interaction output during ordinary and action-like turns. Moshi remains
  responsive, the Pi Console records the miss, pi receives no operation, and the
  Gate 4-selected wording never sounds like affirmative job acceptance. Gate 4
  records the relative conversational disruption and action-safety clarity of
  the neutral and heuristic-gated variants before freezing one.
- Manual full-duplex tests cover interruption during acknowledgement and
  completion, status while pi tools run, typed abort during a tool call,
  console close and reopen, cancellation, failure, and conversation after
  completion.
- Before Gate 2, the Reference-fidelity corpus and rubric are frozen. A turn is
  fully correct only when Moshi materially uses the required fact correctly;
  partial or vague use does not count as fully correct, and ignoring or
  contradicting the Reference fails the turn. Two independent 10-turn runs
  must each reach 8 fully correct turns, reach 17 of 20 in aggregate, and
  contain no direct contradiction.
- Conversation evaluation uses a frozen 20-turn factual and open-ended corpus
  under a prewritten naturalness-and-usefulness rubric, plus separately reported
  freeform turns. At least 16 frozen turns must pass; freeform results cannot be
  substituted to rescue a failed corpus.
- Performance acceptance runs the frozen 100-turn warmed corpus under a
  lightweight configuration and again under the proposed local release model.
  It preserves the 60 ordinary, 20 dispatch, and 20 status composition and
  reports each percentile with its sample count, the count of References
  exceeding 3 seconds, deterministic machinery overhead, derived model
  allowances, model-memory coexistence, and shared-model contention as separate
  results.

## Later

The following ideas remain valuable but are intentionally deferred until Slice
One use demonstrates the need and teaches the correct shape:

- Typed steering of an active pi job from the Pi Console composer, mapped to pi
  RPC `steer`, with pending-boundary tracking (accepted, delivered at pi's
  documented steering boundary, superseded) recorded in the ledger. This is the
  first planned post-slice increment; Slice One uses cancel-and-redispatch.
- Queued follow-ups while a job is running.
- Voice-inferred steering of an active pi job.
- A VoiceClaw-derived rich SwiftUI Activity Surface and persistent visual
  conversation history complementing the deliberately plain Pi Console.
- An embedded terminal emulator (libghostty or SwiftTerm) for the day
  VibeTalker actually hosts a foreign terminal program, such as the native pi
  TUI attached through a pi-supported session-attachment protocol, or a
  general-purpose shell.
- OpenTelemetry-compatible spans, links, exporters, schema migration, and
  external trace viewers.
- Separate conversation, waterfall, and health views; multiple console
  surfaces, sidebar status, logs, and notifications.
- Diagnostic observability modes, raw-payload retention, audio flight recorder,
  and durable replay beyond the small JSONL history.
- Multiple simultaneous mutating workers and cross-project job routing.
- Proactive spoken routine progress rather than status-on-request.
- Selecting arbitrary real projects, intentional self-modification of
  VibeTalker, and controlled modification of pi or Moshi integrations. External
  project access requires an explicit security-scoped-bookmark and helper
  propagation design rather than weakening the app sandbox.
- Explicitly approved external actions through a separately designed narrow
  broker, including delegation to hosted coding systems. Slice One does not
  grant network access to pi-launched commands.
- Rich provider and model switching through a UI.
- Explicit oMLX admission priorities or a separate small Interaction model if
  measurements show shared-model contention.
- Moshi web-client integration beyond the upstream interface needed for Slice
  One.
- Vision and computer-use delegation to Codex or another capable system.

## Out of Scope

- Reimplementing pi's coding agent, provider integrations, session loop,
  compaction, or model catalog.
- Giving Moshi or the Interactor direct filesystem mutation, arbitrary shell,
  pi coding tools, or external-service tools.
- A terminal emulator, PTY, shell, arbitrary terminal programs, or a second
  interactive pi TUI anywhere in Slice One.
- Steering or queuing follow-ups to a running job by voice or by typed input.
- Treating `<ret>`, eager knowledge retrieval, model prose, or ambient speech
  as authorization.
- Requiring a wake word or fixed dispatch phrase.
- Placing pi in the latency-critical ordinary conversation path.
- Multiple active mutating workers in Slice One.
- Writing outside the app-container sandbox project.
- Autonomous modification of global pi configuration, pi source, Moshi-RAG
  source, VibeTalker, or unrelated projects.
- A rich native conversation or activity-history surface beyond the Slice One
  split conversation view and deliberately plain Pi Console.
- A distributed tracing platform, hosted observability service, raw-audio
  archive, or token/frame-level durable telemetry.
- Remote multi-user hosting, accounts, synchronization, or shared execution.
- Silent cloud fallback, job retry, project switching, or permission
  escalation.
- Guaranteeing that Laguna and Moshi-RAG coexist before the Go/No-Go
  measurements.
- Replacing Moshi-RAG with a generic STT/LLM/TTS cascade before the Moshi
  experiments resolve the product's existential risks.

## Further Notes

The original architecture-rich PRD is preserved in Git history at commit
`eb64480`. It remains useful design inventory, particularly for the security
boundary, event model, native Activity Surface, and later observability work.
Deferral in this PRD means "not required to fulfill Slice One," not rejection.

Moshi-RAG already separates its full-duplex front end, streaming ASR,
asynchronous text backend, and Reference conditioning. Its Rust runtime exposes
the existing `set_streaming_sum_condition("reference_with_time", ...)` seam
needed for the first fidelity and completion experiments. Upstream guidance
also warns that retrieval delays beyond roughly three seconds damage response
quality, which is why Reference latency is a product SLO rather than an
interesting metric.

The Responses API is preferred for the Interactor because it supplies a
stateful, typed boundary without placing pi's agent loop in ordinary
conversation. The strict result is typed output for Coordinator validation,
not a function-call tunnel into pi.

The project-naming acknowledgement cannot precede a validated Pi Request, so
its latency and the Interaction decision latency are the same budget. If Gate 4
misses that budget, the first fallback to evaluate is a two-stage experience:
an immediate non-committal verbal receipt followed by the project-naming
committed acknowledgement. The receipt receives its own metric and never
implies that pi started; it cannot be used to make the committed
acknowledgement SLO appear to pass.

Gate 4 reports the observed non-model median and p95 overhead separately. Its
derived model allowances subtract those measurements from the corresponding
product SLOs. These are operational budgets for Gate 6, not a claim that
percentiles from independent distributions compose exactly.

The frozen fidelity, intent, conversation, and latency corpora are regression
contracts sized for Slice One, not statistical proof of production safety.
Their prompts, expected dispositions, and scoring rubrics are written before
execution and retained with results so that the sole evaluator cannot
silently grade a preferred architecture on a curve.

VoiceClaw remains concrete prior art for actor-isolated Mac services, typed
event streams, lifecycle correlation, and SwiftUI presentation. Slice One
deliberately learns from those seams without transplanting its native voice
engine or prematurely building the rich Activity Surface.

The Xcode app is a security decision as much as a presentation decision. Pi's
own security documentation says project trust is not a sandbox and real
isolation must come from the operating system or a virtualization/container
boundary. App Sandbox supplies the stable write boundary for the embedded pi
process. Because the app requires network-client capability for model and
speech traffic and that entitlement is not restricted to localhost, the nested
network-denied command profile remains required even in an all-local
configuration.

`sandbox-exec` is a legacy macOS interface, so Gate 0 records the target macOS
version and proves the exact signed-build profile rather than assuming it works
from an unsandboxed terminal experiment. Failure stops the gate; VibeTalker
never falls back to unsandboxed command execution. A future replacement may use
an XPC tool broker or a pi-supported isolation backend without changing the
Coordinator contract.

The Node helper adds a second platform risk under Hardened Runtime because V8
normally uses JIT-compiled code. Gate 0 proves the narrow allow-JIT entitlement
on the actual Apple silicon and macOS target and retains `--jitless` as a
measured fallback. Broader executable-memory or library-validation exceptions
are not acceptable substitutes for a failed spike.

Slice One deliberately keeps the coding workspace in the app container.
User-selected folder access is dynamically granted by macOS and does not
automatically become part of an embedded helper's static inherited sandbox.
Persistent bookmarks and helper propagation are valid later mechanisms, but
they are unnecessary complexity for proving the first voice-to-code loop.

The Pi Console is deliberately not a terminal emulator. No foreign program runs
in it: pi is driven over typed RPC, the observer projection is VibeTalker's own
ledger, and Slice One's Out of Scope forbids the shell, arbitrary programs, and
the pi TUI, which are the only jobs terminal emulation performs. Attaching a
terminal to the session would provide the appearance of directness while
complicating ownership of the session; the RPC composer provides genuine direct
interaction with the same pi session the Coordinator owns. Terminal-neutrality
is preserved by the ledger being the contract: the same projection is available
to any external terminal through `vibetalker observe --follow`. An embedded
terminal emulator returns to scope only when a foreign terminal program does.

Typed steering was evaluated for Slice One and deliberately deferred. Pi RPC
supports `steer` natively, but adopting it in the first slice adds
pending-boundary tracking, supersession semantics, additional arbitration
races, new tests, and a wider Product Promise for a correction case that
cancel-and-redispatch already covers with the retained pi session's context. It
is the first planned post-slice increment because most of the serialization
machinery it needs already exists for the composer.

cmux remains the developer's preferred external terminal and can run
`vibetalker observe --follow` manually. VibeTalker has no cmux launcher,
socket, capability probe, access-mode setting, or runtime dependency.

The command sandbox prevents tool-initiated network access, not all possible
data egress. The pi process must communicate with its configured inference
provider, and workspace content included in model context can reach that
provider. Choosing local oMLX keeps that path local; choosing a hosted provider
is an explicit privacy decision disclosed before the session begins.

The preferred long-term configuration remains Moshi-RAG and Laguna through
oMLX on the 128 GB M4 Max, with pi able to choose Laguna or another coding
backend. Slice One begins with lighter components to prove the protocol and
experience, then accepts a local release model only after measuring the whole
machine rather than adding model memory estimates on paper.

## References and Pinned Dependencies

- **Moshi-RAG:** [kyutai-labs/moshi-rag](https://github.com/kyutai-labs/moshi-rag)
  and the [Moshi-RAG paper](https://arxiv.org/abs/2604.12928). Gate 1 records
  the exact source commit, Rust/Candle Metal feature set, model revisions, STT
  mode, and Reference Encoder topology used by all later gates. The relevant
  upstream weights are `kyutai/moshika-rag-candle-bf16` for the Rust path and
  `kyutai/moshika-rag-pytorch-bf16` for the research path.
- **pi:** [earendil-works/pi](https://github.com/earendil-works/pi) and
  [pi.dev](https://pi.dev/). The inspected development baseline is
  `v0.80.2-70-g5a073885` at commit
  `5a073885b5f23cd6125cda0927cf50acf2bf22fb`; the RPC contract is
  `packages/coding-agent/docs/rpc.md`, and the security contract is
  `packages/coding-agent/docs/security.md`. The implementation pins the helper
  revision rather than consuming an ambient installation.
- **Laguna:** [poolside/Laguna-S-2.1-NVFP4-mlx](https://huggingface.co/poolside/Laguna-S-2.1-NVFP4-mlx)
  is the approximately 71.9 GB MLX release candidate for Gate 6; the
  [base model card](https://huggingface.co/poolside/Laguna-S-2.1) is
  authoritative for usage and license, and the
  [NVFP4 model card](https://huggingface.co/poolside/Laguna-S-2.1-NVFP4)
  documents the roughly 117.6B-total, 8.5B-active MoE architecture. Gate 6 pins
  the exact Hugging Face revisions and measures actual oMLX cache behavior
  rather than assuming the advertised FP8 KV-cache representation is preserved.
- **oMLX:** [jundot/omlx](https://github.com/jundot/omlx). The inspected daily
  checkout is commit
  `4177294074b6d0394693760839eb8e0e367d4feb`, which implements
  `/v1/responses`, typed streaming events, and persisted
  `previous_response_id` state. Release diagnostics verify those capabilities
  against the running server.
- **macOS security platform:** Apple's
  [App Sandbox overview](https://developer.apple.com/documentation/security/app-sandbox),
  [sandboxed helper guidance](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app),
  [JIT entitlement guidance](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit),
  and
  [sandboxed file-access guidance](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
  define the signing, inheritance, container, and later
  security-scoped-bookmark model. The effective signed products and runtime
  escape fixtures, rather than the source entitlement plist alone, are the
  acceptance evidence.
- **Ghostty/libghostty:**
  [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty). Later-phase
  reference only, not a Slice One dependency: relevant if a future increment
  hosts a foreign terminal program. Its embedding API is currently unversioned
  and would require pinning an exact source revision.
- **Audex-Mac:** [mbarnson/Audex-Mac](https://github.com/mbarnson/Audex-Mac)
  is local voice-interface prior art, not a runtime dependency. The inspected
  baseline is commit `0ca7ac3f9184cc12b69480dbaac2b5d99ef0177c`
  in `/Users/patbarnson/devel/Audex-Mac`.
- **VoiceClaw:** local prior art for actor isolation, native service lifecycle,
  event streams, and SwiftUI presentation, not a runtime dependency. The
  inspected baseline is commit
  `3aa23f509c39897ecc8052c33c7b241faad6327c` in
  `/Users/patbarnson/devel/voiceclaw`; its live working tree may contain
  uncommitted experiments and is not treated as a pinned dependency.
