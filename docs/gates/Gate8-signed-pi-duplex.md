# Gate 8 — Signed pi/full-duplex coexistence

Status: **passed**

PRDv2 requires one ten-minute full-duplex session to remain free of audible
underruns or conversation stalls while pi performs a representative coding
task. Gate 1 proved the ten-minute local Moshi transport and Gate 5 proved the
signed voice-to-pi vertical slice separately. This gate exercises both
conditions in one signed-app session.

## Signed topology

The test uses the current Xcode-built and Apple Development-signed
`VibeTalker.app`. The app must report:

- native preflight ready;
- hosted OpenAI Responses selected for Interaction;
- pi RPC connected with its configured coding provider;
- Coordinator adapter ready;
- local Moshi-RAG topology ready.

The acceptance harness does not start or supervise its own model processes.
It connects to the app-owned Moshi WebSocket at
`http://127.0.0.1:8999/api/chat` and the app-owned Coordinator at
`http://127.0.0.1:8173`.

## Frozen workload

Fifteen seconds after streaming begins, the harness commits this canonical
coding request through the same Coordinator transcript endpoint used by local
streaming ASR:

```text
Create a file named signed-duplex-probe.txt containing exactly signed duplex
acceptance, then read it back to verify. Do not modify any other file.
```

It commits grounded status questions at 120, 300, and 540 seconds. In parallel,
ten synthesized marker prompts are streamed to Moshi at one-minute intervals.
PCM is injected and captured directly over loopback; no Core Audio output
device is opened.

## Automated checks

The retained fixture must prove:

- at least 600 seconds elapsed;
- at least 95 percent decoded-output coverage;
- p99 packet gap below 150 milliseconds;
- maximum packet gap below 500 milliseconds;
- at least eight of ten local-ASR markers recognized;
- at least five prompts actively interrupted ongoing model output;
- the coding request and all three status requests were accepted;
- the Coordinator remained healthy before and after the run;
- a second Moshi WebSocket handshake succeeded without restarting the app.

The signed Pi Console is inspected after the run for the correlated accepted
job, authoritative write/read tool events, terminal completion, grounded
status, and proactive completion delivery. Those events—not the transcript
HTTP acknowledgement—prove that pi actually performed the task.

## Accepted result

The definitive run on July 25, 2026 used a fresh signed app process with
OpenAI selected for both the hosted Responses Interactor and pi coding
provider. The retained fixture records:

| Measurement | Result |
| --- | ---: |
| Elapsed time | 601.178 s |
| Decoded-output coverage | 98.32% |
| Output packets | 7,374 |
| Median packet gap | 81.3 ms |
| p95 packet gap | 86.9 ms |
| p99 packet gap | 89.9 ms |
| Maximum packet gap | 213.5 ms |
| Terminal output gap | 0 ms |
| Half-second stalls | 0 |
| Local-ASR markers recognized | 9/10 |
| Active output interruptions | 9 |
| Coordinator requests accepted | 4/4 |
| Moshi reconnect | passed |

All automated checks passed. The canonical coding request completed its
Responses classification in 1.437 seconds; the three grounded status turns
completed in 1.396, 1.373, and 1.163 seconds. The Coordinator was ready before
and after the run, and the client WebSocket reconnected without restarting the
app or pi.

A preceding signed source run supplied the authoritative Pi Console evidence:
pi wrote `signed-duplex-probe.txt`, read it back as exactly
`signed duplex acceptance`, reached terminal completion, and queued the
proactive Reference. The quantitative fixture only claims Coordinator
acceptance; it deliberately does not substitute an HTTP acknowledgement for
those ledger events.

The harness now records the ten largest internal packet gaps and the terminal
gap from the final output packet to the 600-second deadline. This prevents a
stream that stops early from passing merely because its earlier packet gaps
were small.

The accepted run must begin on a fresh Moshi process. The pinned runtime
allocates 20,000 Mimi positions at 25 positions per second, an 800-second
process-lifetime bound. `rustymimi.StreamTokenizer` persists across WebSocket
connections, so reusing a process after prior long diagnostic traffic can
exhaust that position budget even though a new client session was opened.
PRDv2 requires one fresh ten-minute session; extending the same process across
multiple ten-minute sessions is not claimed by this gate.

## Reproduction

For unattended source acceptance, launch the signed app without opening a
browser or taking keyboard focus:

```sh
VIBETALKER_ACCEPTANCE_AUTOSTART=1 \
  scripts/run-vibetalker-dev.sh openai openai \
  -ApplePersistenceIgnoreState YES
```

The environment flag is development-only and is not persisted. It runs native
preflight, waits for pi RPC, and starts the local voice runtime. Once
`http://127.0.0.1:8173/health` reports ready, run:

```sh
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-signed-pi-duplex.py
```

The WAV remains ignored under `tmp/Acceptance-audio/`. The passing summary
will be retained at `Fixtures/Acceptance/signed-pi-duplex-q8.json`.
