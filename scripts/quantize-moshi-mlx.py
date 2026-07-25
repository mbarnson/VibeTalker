#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn

from moshi_mlx import models


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Quantize converted Moshi-RAG MLX weights."
    )
    parser.add_argument("configuration", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--bits", type=int, choices=(4, 8), default=8)
    args = parser.parse_args()

    with args.configuration.open(encoding="utf-8") as handle:
        configuration = models.LmConfig.from_config_dict(json.load(handle))

    model = models.Lm(configuration)
    model.set_dtype(mx.bfloat16)
    model.load_weights(str(args.source), strict=True)

    group_size = 32 if args.bits == 4 else 64
    nn.quantize(
        model,
        bits=args.bits,
        group_size=group_size,
        class_predicate=lambda path, module: (
            not path.startswith("condition_provider.")
            and hasattr(module, "to_quantized")
        ),
    )
    model.save_weights(str(args.destination))
    print(args.destination)


if __name__ == "__main__":
    main()
