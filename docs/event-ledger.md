# Event Ledger

VibeTalker persists its ordered activity stream as append-only JSONL at:

```text
~/Library/Containers/org.barnson.VibeTalker/Data/Library/Application Support/VibeTalker/EventLedger/events.jsonl
```

Each record has a versioned envelope with a stable event identity, sequence,
monotonic and wall-clock timestamps, source, kind, redacted message, and
optional voice-session, utterance, revision, Interaction-request, and
Action-Job identifiers. The native console restores a bounded recent tail from
this file at launch.

## Observe from a terminal

The source-tree observer provides the PRD's terminal-neutral recent-history and
follow projection:

```sh
scripts/vibetalker-observe.swift --recent 100 --follow
```

Use `--path` to inspect a fixture or a ledger copied out of another container:

```sh
scripts/vibetalker-observe.swift \
  --path /tmp/events.jsonl \
  --recent 25
```

Run `scripts/vibetalker-observe.swift --help` for all options. Because this is
a Swift source executable, the active Xcode command-line toolchain supplies its
runtime compilation. Terminal, Codex, or another observer process may require
macOS Privacy & Security permission to read another sandboxed app's container;
VibeTalker itself does not request that permission.

The ledger deliberately excludes high-volume partial transcripts, model
tokens, audio activity, hidden reasoning, and raw audio. Credential-shaped
values are redacted before both in-memory publication and persistence.
