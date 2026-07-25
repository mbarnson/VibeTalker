# Gate 1: Upstream Moshi-RAG Baseline

Status: **upstream baseline failed; optimized-path investigation in progress**

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

The initial checkout under `Vendor/moshi-rag` was built and run unmodified from
that detached upstream revision. Controlled local patches were then used to
isolate the runtime failures described below. Those ignored checkout edits are
not accepted product source; any retained change must become a tracked,
reproducible patch.

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

## Unmodified runtime result

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

Live microphone input exposed two upstream runtime failures:

- The default batched path failed with a Candle concatenation dtype mismatch:
  `lhs: F32, rhs: BF16`.
- With `batch_size` reduced to 1, the separate Candle `MetalDevice` instances
  failed a convolution with a device mismatch even though both represented the
  same physical GPU.

Therefore the unmodified Moshi-RAG Metal backend does not pass Gate 1 on the
acceptance Mac.

## Controlled diagnostic patch

A local diagnostic patch reused one exact Candle `MetalDevice` instance for the
main model, STT model, and STT Mimi when they target the same GPU. It also moved
incoming PCM to the STT Mimi device. That eliminated the device mismatch and
produced a functional live session:

- microphone input reached local streaming ASR;
- Moshi produced live speech and text;
- the backend queried the deterministic Reference fixture;
- Moshi spoke the unique fixture fact `cobalt`.

This validates the Reference/ARC topology but does not pass the latency
requirement. F32 accumulated roughly 44 seconds of latency after 44 seconds of
playback. BF16 reduced the backlog substantially, but still accumulated roughly
11 seconds of latency after 29 seconds and produced clearly audible stuttering.

## Apple Silicon optimization investigation

Kyutai's base Moshi repository explicitly provides MLX for on-device inference
on Mac and iPhone. Its runner uses:

- BF16 model compute;
- native MLX 4-bit or 8-bit quantization;
- a full codec/model warm-up;
- separate client/audio and model processes;
- an `mlx-trace.json` trace containing model, encode, decode, queue-depth, and
  lag events.

The reproducibility manifest pins this experiment to:

- Repository: `https://github.com/kyutai-labs/moshi.git`
- Revision: `e6a55d2722a65870ef52a6c9f6ecfc0e90f38362`
- Package: `moshi_mlx`

The MLX implementation is not assumed to be a drop-in replacement. The
Moshi-RAG fork's ARC Reference conditioning and embedded streaming STT remain in
its Rust/Candle topology. The next test is a q4 MLX base-Moshi latency baseline
on the same acceptance Mac. If that is real-time, it establishes the optimized
execution target and bounds the work needed to preserve Reference conditioning.
