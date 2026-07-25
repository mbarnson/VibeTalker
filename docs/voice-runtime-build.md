# Voice runtime source build

VibeTalker's Apple-Silicon voice runtime is built from the exact GitHub
revisions in `Dependencies/upstreams.json`. The ignored `Vendor` checkouts are
build products, not authoritative source.

Run:

```sh
scripts/build-voice-runtime-from-source.sh
```

The builder:

1. clones Kyutai Moshi and Moshi-RAG at the pinned revisions;
2. applies the tracked Apple-Silicon patches under `Patches/`;
3. requires the accepted CPython 3.12.11 runtime and creates isolated
   environments with `uv` when available;
4. installs MLX Moshi and the narrow ARC service dependency set from source
   using the exact transitive versions in the tracked lock files;
5. resolves every model and tokenizer at a pinned Hugging Face revision;
6. reuses revision-addressed local cache files when present;
7. converts the pinned Moshi-RAG BF16 checkpoint to MLX; and
8. writes the runtime layout expected by `RuntimeInstallation`.

The default staging destination is `Vendor/voice-runtime`, which is excluded
from Git. An absolute destination may be passed as the first argument.

The staging step intentionally does not write into
`~/Library/Containers/org.barnson.VibeTalker`. macOS prevents Terminal and
other developer tools from directly mutating an app's protected container.
The signed app must perform the final import into its own Application Support
directory.

## Reproducibility evidence

On the Gate 1 acceptance Mac, a clean run produced an MLX BF16 checkpoint
bit-for-bit identical to the checkpoint used by the successful live
conditioning experiment:

```text
SHA-256 544996b57b40cf3bf99c3ddcbd1bbd1da195a04b4ce43846d576bb801e75c867
```

Both tracked patches pass `git apply --check` against pristine clones of their
pinned revisions.

The source-built ARC service was launched offline on MPS and accepted:

```json
{"text":"The verification color is cobalt, and no other color is correct."}
```

Its `/embed` response was a 65,616-byte safetensors payload containing
`tensor: float32[1, 4, 4096]`. This verifies the actual local tokenizer,
checkpoint, MPS execution, serialization, and HTTP boundary—not merely CLI
argument parsing.
