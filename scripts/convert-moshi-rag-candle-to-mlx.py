#!/usr/bin/env python3
"""Convert Kyutai's sliced Candle Moshi-RAG checkpoint to MLX names."""

from __future__ import annotations

import argparse
from pathlib import Path

from safetensors.torch import load_file, save_file


GENERATED_CODEBOOKS = 8


def convert_name(name: str) -> tuple[str, bool] | None:
    if name.startswith("emb."):
        return name.replace("emb.", "audio_embs.", 1), False
    if name.startswith("depformer."):
        _, slice_text, remainder = name.split(".", 2)
        slice_index = int(slice_text)
        if slice_index >= GENERATED_CODEBOOKS:
            return None
        name = f"depformer.slices.{slice_index}.{remainder}"
    elif name.startswith("condition_provider.") and not name.startswith(
        "condition_provider.conditioners.first_speaker."
    ):
        return None

    squeeze_norm = name == "out_norm.alpha" or name.endswith(
        (".norm1.alpha", ".norm2.alpha")
    )
    name = name.replace("out_norm.alpha", "out_norm.weight")
    name = name.replace(".norm1.alpha", ".norm1.weight")
    name = name.replace(".norm2.alpha", ".norm2.weight")
    name = name.replace(".self_attn.in_proj_weight", ".self_attn.in_proj.weight")
    return name, squeeze_norm


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    source = load_file(args.source, device="cpu")
    converted = {}
    for source_name, tensor in source.items():
        mapping = convert_name(source_name)
        if mapping is None:
            continue
        destination_name, squeeze_norm = mapping
        if destination_name in converted:
            raise RuntimeError(f"duplicate converted key: {destination_name}")
        converted[destination_name] = (
            tensor[0, 0].contiguous() if squeeze_norm else tensor
        )

    expected = {
        f"depformer.slices.{index}.linear_out.weight"
        for index in range(GENERATED_CODEBOOKS)
    }
    missing = sorted(expected - converted.keys())
    if missing:
        raise RuntimeError(
            "converted checkpoint is missing speech depformer slices: "
            + ", ".join(missing)
        )

    args.destination.parent.mkdir(parents=True, exist_ok=True)
    save_file(
        converted,
        args.destination,
        metadata={
            "format": "pt",
            "source_layout": "kyutai-moshi-rag-candle-sliced",
        },
    )


if __name__ == "__main__":
    main()
