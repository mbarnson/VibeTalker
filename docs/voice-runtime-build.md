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
3. copies the accepted CPython 3.12.11 runtime into the payload so no
   developer-machine interpreter path survives import;
4. installs isolated MLX and ARC `site-packages` trees from source using the
   exact transitive versions in the tracked lock files;
5. resolves every model and tokenizer at a pinned Hugging Face revision;
6. reuses revision-addressed local cache files when present;
7. maps the pinned sliced Candle Moshi-RAG checkpoint into MLX, including all
   eight generated speech depformer slices;
8. regenerates Q8 from that validated BF16 checkpoint; and
9. writes the runtime layout expected by `RuntimeInstallation`.

The default staging destination is `Vendor/voice-runtime`, which is excluded
from Git. An absolute destination may be passed as the first argument.

The staging step intentionally does not write into
`~/Library/Containers/org.barnson.VibeTalker`. macOS prevents Terminal and
other developer tools from directly mutating an app's protected container.
The signed app must perform the final import into its own Application Support
directory.

## Reproducibility evidence

On the Gate 2 acceptance Mac, a clean pinned-source run produced:

```text
BF16 a833601754bb6cb9b2d4730d808d7f261da607f64e18a00d7c0ad49456d6c0c3
Q8   e9005a1bab2d766a73a63dd33ef4a56a59bbae1d268c0d7eef971be607e5e501
```

The BF16 file contains 526 tensors. Each of
`depformer.slices.0` through `depformer.slices.7` contains 39 tensors, and the
runtime passes a strict checkpoint load. The source builder always regenerates
BF16 and Q8 so a stale conversion cannot survive a rebuild.

The source-built ARC service was launched offline on MPS and accepted:

```json
{"text":"The verification color is cobalt, and no other color is correct."}
```

Its `/embed` response was a 65,616-byte safetensors payload containing
`tensor: float32[1, 4, 4096]`. This verifies the actual local tokenizer,
checkpoint, MPS execution, serialization, and HTTP boundary—not merely CLI
argument parsing.
