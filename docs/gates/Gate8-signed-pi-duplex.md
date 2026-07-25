# Gate 8 — Signed pi/full-duplex coexistence

Status: **harness frozen; acceptance run pending**

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

## Reproduction

After launching the signed app with the configured provider environment,
run native preflight, start pi, and start the local voice runtime. Then:

```sh
Vendor/voice-runtime/Python/bin/python3.12 \
  scripts/run-signed-pi-duplex.py
```

The WAV remains ignored under `tmp/Acceptance-audio/`. The passing summary
will be retained at `Fixtures/Acceptance/signed-pi-duplex-q8.json`.
