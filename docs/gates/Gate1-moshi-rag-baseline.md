# Gate 1: Upstream Moshi-RAG Baseline

Status: **runtime verification in progress**

Recorded 2026-07-24 on the acceptance Mac:

- MacBook Pro `Mac16,5`
- Apple M4 Max, 16 CPU cores
- 128 GB unified memory
- Rust 1.92.0
- Cargo 1.92.0
- Apple clang 21.0.0

## Pinned upstream

- Repository: `https://github.com/kyutai-labs/moshi-rag.git`
- Revision: `8c6dfc101b7871baa428424bcdc583b74fb561d9`

The checkout under `Vendor/moshi-rag` is ignored by the VibeTalker repository
and remains unmodified. The official Rust backend and web client are built from
that detached upstream revision.

## Source build

The Metal backend builds successfully with the upstream lockfile:

```sh
cd Vendor/moshi-rag/rust
CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  cargo build --locked --features metal --bin moshi-backend --release
```

`CMAKE_POLICY_VERSION_MINIMUM=3.5` is required because the pinned
`sentencepiece-sys` dependency uses an older CMake policy than the CMake version
installed on the acceptance Mac. No upstream source was changed.

The official client also builds successfully:

```sh
cd Vendor/moshi-rag/client
npm install
npm run build
```

The upstream npm audit currently reports 22 dependency findings: 5 moderate,
16 high, and 1 critical. Gate 1 records that baseline without changing the
pinned client dependency graph.

## Pinned model artifacts

| Purpose | Repository revision | Artifact |
| --- | --- | --- |
| Moshi-RAG | `kyutai/moshika-rag-candle-bf16@26c8294761455c0aaafbadc6772c890fdc11f68f` | `model.safetensors`, tokenizer, Mimi |
| Local STT | `kyutai/stt-1b-en_fr-candle@095e38f6242006a93c2541149b181988397f5c7c` | `model.safetensors`, tokenizer, Mimi |
| Reference encoder | `kyutai/ARC4_Encoder_Llama@f27d986b193bfdff742d54412d3057b498ec8cc9` | `model.safetensors` |
| ARC tokenizer | `meta-llama/Llama-3.2-3B-Instruct` | `tokenizer.json` |

The approximate weight payload is 31.6 GB before cache metadata.

## Reference topology

The accepted Rust standalone embeds the ARC Reference Encoder. It does not
require the separately supervised Python conditioner service:

- `moshi-core/src/lm.rs` constructs the `reference_with_time` ARC encoder in
  `v0_1_streaming_rag`.
- `moshi-backend/src/stream_both.rs` applies the resulting streaming sum
  condition under `reference_with_time`.
- The same Rust process embeds the local streaming STT model and Mimi codec.

The upstream backend requests Reference text from an OpenAI-compatible
`/v1/chat/completions` endpoint. Gate 1 uses
`scripts/reference-fixture-server.mjs` to return a deterministic local response
with the unique verification fact `cobalt`, allowing Reference conditioning to
be checked without a hosted provider.

## Runtime acceptance evidence

The pinned release backend reached all of the following milestones on Metal:

- `model is ready to roll!`
- standalone listener active at `http://127.0.0.1:8998`
- batched local STT LM and STT Mimi initialized on Metal
- batched model loop started
- `/api/availability` returned `{"available":true}`
- the official client HTML returned HTTP 200

A protocol probe received server metadata followed by the binary Moshi
handshake. Three subsequent connect/disconnect/reconnect probes all received
the same metadata/handshake sequence. Backend logs recorded every accepted
connection and clean decoder/socket closure, proving that reconnect does not
require a backend restart.

The following live-audio evidence is still required before this gate can pass:

- microphone input and local streaming ASR
- full-duplex model speech
- barge-in while the model is speaking
- learned `<ret>` retrieval and spoken use of the `cobalt` Reference

The runtime uses an ignored localhost-only configuration that changes
`use_https` to `false` and binds to `127.0.0.1`. Model topology, weights, source,
and executable remain the pinned upstream baseline.

Safari is currently waiting for explicit approval to grant the localhost site
microphone access. No microphone permission was granted or bypassed while
collecting the non-audio evidence above.
