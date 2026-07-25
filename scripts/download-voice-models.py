#!/usr/bin/env python3
"""Download the exact voice artifacts pinned by VibeTalker."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil

from huggingface_hub import hf_hub_download, snapshot_download


MOSHIKA_REPOSITORY = "kyutai/moshika-rag-candle-bf16"
MOSHIKA_REVISION = "26c8294761455c0aaafbadc6772c890fdc11f68f"
ARC_REPOSITORY = "kyutai/ARC4_Encoder_Llama"
ARC_REVISION = "f27d986b193bfdff742d54412d3057b498ec8cc9"
TOKENIZER_REPOSITORY = "meta-llama/Llama-3.2-3B-Instruct"
TOKENIZER_REVISION = "0cb88a4f764b7a12671c53f0838cd831a0843b95"


def materialize(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.stat().st_size == source.stat().st_size:
            return
        raise RuntimeError(f"existing artifact has the wrong size: {destination}")
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def download_file(
    repository: str,
    revision: str,
    filename: str,
    cache_directory: Path,
) -> Path:
    source_cache = Path.home() / ".cache/huggingface/hub"
    try:
        return Path(
            hf_hub_download(
                repo_id=repository,
                revision=revision,
                filename=filename,
                cache_dir=source_cache,
                local_files_only=True,
            )
        )
    except Exception:
        return Path(
            hf_hub_download(
                repo_id=repository,
                revision=revision,
                filename=filename,
                cache_dir=cache_directory,
            )
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime_root", type=Path)
    parser.add_argument("conditioner_config_template", type=Path)
    args = parser.parse_args()

    runtime_root = args.runtime_root.expanduser().resolve()
    cache_directory = runtime_root / "HuggingFace"
    model_directory = runtime_root / "Models"
    cache_directory.mkdir(parents=True, exist_ok=True)
    model_directory.mkdir(parents=True, exist_ok=True)

    artifacts = {
        "moshika-rag-pytorch-bf16.safetensors": "model.safetensors",
        "tokenizer_spm_32k_3.model": "tokenizer_spm_32k_3.model",
        "tokenizer-e351c8d8-checkpoint125.safetensors":
            "tokenizer-e351c8d8-checkpoint125.safetensors",
    }
    for destination_name, source_name in artifacts.items():
        source = download_file(
            MOSHIKA_REPOSITORY,
            MOSHIKA_REVISION,
            source_name,
            cache_directory,
        )
        materialize(source, model_directory / destination_name)

    # The conditioner resolves these from the managed HF cache at the exact
    # revisions carried in its tracked configuration.
    arc_source = download_file(
        ARC_REPOSITORY,
        ARC_REVISION,
        "model.safetensors",
        cache_directory,
    )
    arc_destination = model_directory / "arc4-encoder-llama.safetensors"
    materialize(arc_source, arc_destination)

    tokenizer_patterns = [
        "config.json",
        "generation_config.json",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
    ]
    source_cache = Path.home() / ".cache/huggingface/hub"
    try:
        tokenizer_source = Path(snapshot_download(
            repo_id=TOKENIZER_REPOSITORY,
            revision=TOKENIZER_REVISION,
            cache_dir=source_cache,
            allow_patterns=tokenizer_patterns,
            local_files_only=True,
        ))
    except Exception:
        tokenizer_source = Path(snapshot_download(
            repo_id=TOKENIZER_REPOSITORY,
            revision=TOKENIZER_REVISION,
            cache_dir=cache_directory,
            allow_patterns=tokenizer_patterns,
        ))
    tokenizer_destination = model_directory / "Llama-3.2-3B-Instruct-tokenizer"
    for source in tokenizer_source.rglob("*"):
        if source.is_file():
            materialize(
                source.resolve(),
                tokenizer_destination / source.relative_to(tokenizer_source),
            )

    with args.conditioner_config_template.open(encoding="utf-8") as handle:
        config = json.load(handle)
    conditioner = config["conditioners"]["reference_with_time"][
        "multi_arc_encoder"
    ]
    # Keep the generated runtime relocatable. The app launches the conditioner
    # with the managed runtime root as its working directory.
    conditioner["model_path"] = str(
        arc_destination.relative_to(runtime_root)
    )
    conditioner["tokenizer_name"] = str(
        tokenizer_destination.relative_to(runtime_root)
    )
    conditioner.pop("hf_repo", None)
    conditioner.pop("hf_revision", None)
    conditioner.pop("tokenizer_revision", None)
    with (runtime_root / "moshi-rag-config.json").open(
        "w", encoding="utf-8"
    ) as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
