#!/usr/bin/env python3
"""Prove that Moshi speaks an externally initiated completion without user speech."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import time
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parent
GATE2_RUNNER = SCRIPT_ROOT / "run-gate2-reference-fidelity.py"
GATE2_SPEC = importlib.util.spec_from_file_location(
    "vibetalker_gate2_runtime",
    GATE2_RUNNER,
)
if GATE2_SPEC is None or GATE2_SPEC.loader is None:
    raise RuntimeError(f"could not load shared Moshi runtime from {GATE2_RUNNER}")
gate2 = importlib.util.module_from_spec(GATE2_SPEC)
sys.modules[GATE2_SPEC.name] = gate2
GATE2_SPEC.loader.exec_module(gate2)

import aiohttp
import numpy as np
import sphn


DEFAULT_REFERENCE = (
    "Say exactly this completion announcement and nothing else: The Workspace "
    "project is complete. The Gate Three verification marker is ultraviolet. "
    "Repeat the exact announcement: The Workspace project is complete. The "
    "Gate Three verification marker is ultraviolet."
)
REQUIRED_PHRASES = ("workspace", "complete", "ultraviolet")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runtime-root",
        type=Path,
        default=Path("Vendor/voice-runtime"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Fixtures/Gate3/results/proactive-completion-q8.json"),
    )
    parser.add_argument(
        "--audio-output",
        type=Path,
        default=Path("tmp/Gate3-audio/proactive-completion.wav"),
    )
    parser.add_argument("--log-dir", type=Path)
    parser.add_argument("--precision", choices=("bf16", "q8"), default="q8")
    parser.add_argument("--warmup-seconds", type=float, default=4.0)
    parser.add_argument("--capture-seconds", type=float, default=20.0)
    parser.add_argument("--reference", default=DEFAULT_REFERENCE)
    parser.add_argument(
        "--whisper-model",
        default="mlx-community/whisper-small-mlx",
    )
    parser.add_argument("--skip-whisper", action="store_true")
    return parser.parse_args()


def normalized(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


async def run_probe(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
) -> dict[str, Any]:
    output_pcm: list[np.ndarray] = []
    model_text: list[str] = []
    asr_text: list[str] = []
    reference_started_at: float | None = None
    reference_completed_at: float | None = None
    first_audio_at: float | None = None
    first_model_text_at: float | None = None
    marker_text_at: float | None = None
    reference_payload: dict[str, Any] = {}
    started_at = time.monotonic()
    stop_at = started_at + args.warmup_seconds + args.capture_seconds

    async with session.ws_connect(
        "http://127.0.0.1:8999/api/chat",
        timeout=aiohttp.ClientTimeout(total=None, sock_connect=5),
        max_msg_size=8 * 1_024 * 1_024,
    ) as websocket:
        handshake = await websocket.receive(timeout=5)
        if (
            handshake.type != aiohttp.WSMsgType.BINARY
            or handshake.data != b"\x00"
        ):
            raise RuntimeError("Moshi returned an invalid WebSocket handshake")

        opus_writer = sphn.OpusStreamWriter(gate2.SAMPLE_RATE)
        opus_reader = sphn.OpusStreamReader(gate2.SAMPLE_RATE)

        async def inject_reference() -> dict[str, Any]:
            nonlocal reference_completed_at
            async with session.post(
                "http://127.0.0.1:8999/api/proactive",
                json={"text": args.reference},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as response:
                payload = await response.json()
                response.raise_for_status()
                reference_completed_at = time.monotonic()
                return payload

        async def receive() -> None:
            nonlocal first_audio_at, first_model_text_at, marker_text_at
            while time.monotonic() < stop_at + 1:
                remaining = max(0.1, stop_at + 1 - time.monotonic())
                try:
                    message = await websocket.receive(timeout=remaining)
                except TimeoutError:
                    return
                if message.type != aiohttp.WSMsgType.BINARY:
                    if message.type in {
                        aiohttp.WSMsgType.CLOSE,
                        aiohttp.WSMsgType.CLOSED,
                        aiohttp.WSMsgType.ERROR,
                    }:
                        return
                    continue
                data = message.data
                if not data:
                    continue
                kind, body = data[0], data[1:]
                if kind == 1:
                    decoded = opus_reader.append_bytes(body)
                    if (
                        reference_started_at is not None
                        and decoded.shape[-1] > 0
                    ):
                        if first_audio_at is None:
                            first_audio_at = time.monotonic()
                        output_pcm.append(np.asarray(decoded, dtype=np.float32))
                elif kind == 2 and reference_started_at is not None:
                    if first_model_text_at is None:
                        first_model_text_at = time.monotonic()
                    model_text.append(body.decode("utf-8", errors="replace"))
                    if (
                        marker_text_at is None
                        and "ultraviolet" in normalized("".join(model_text))
                    ):
                        marker_text_at = time.monotonic()
                elif kind == 7 and body.startswith(b"\x0a"):
                    asr_text.append(body[1:].decode("utf-8", errors="replace"))

        receiver = asyncio.create_task(receive())
        reference_task: asyncio.Task[dict[str, Any]] | None = None
        silence = np.zeros(gate2.FRAME_SIZE, dtype=np.float32)
        while time.monotonic() < stop_at:
            if (
                reference_task is None
                and time.monotonic() - started_at >= args.warmup_seconds
            ):
                reference_started_at = time.monotonic()
                reference_task = asyncio.create_task(inject_reference())
            encoded = opus_writer.append_pcm(silence)
            if encoded:
                await websocket.send_bytes(b"\x01" + encoded)
            await asyncio.sleep(gate2.FRAME_SIZE / gate2.SAMPLE_RATE)
        await receiver
        if reference_task is None:
            raise RuntimeError("proactive Reference was not scheduled")
        reference_payload = await reference_task

    if reference_started_at is None or reference_completed_at is None:
        raise RuntimeError("proactive Reference timing was not recorded")

    rendered = (
        np.concatenate(output_pcm)
        if output_pcm
        else np.zeros(0, dtype=np.float32)
    )
    args.audio_output.parent.mkdir(parents=True, exist_ok=True)
    audio_sha256 = None
    streaming_stt_transcript = ""
    audible_transcript = ""
    if rendered.shape[-1] > 0:
        sphn.write_wav(
            str(args.audio_output),
            rendered,
            sample_rate=gate2.SAMPLE_RATE,
        )
        audio_sha256 = hashlib.sha256(
            args.audio_output.read_bytes()
        ).hexdigest()
        streaming_stt_transcript = await gate2.transcribe_pcm(session, rendered)
        audible_transcript = (
            streaming_stt_transcript
            if args.skip_whisper
            else gate2.transcribe_with_whisper(
                args.audio_output,
                args.whisper_model,
            )
        )

    response = audible_transcript or streaming_stt_transcript
    normalized_response = normalized(response)
    required_phrases_present = {
        phrase: phrase in normalized_response
        for phrase in REQUIRED_PHRASES
    }
    first_audio_latency = (
        None
        if first_audio_at is None
        else first_audio_at - reference_started_at
    )
    marker_text_latency = (
        None
        if marker_text_at is None
        else marker_text_at - reference_started_at
    )
    first_model_text_latency = (
        None
        if first_model_text_at is None
        else first_model_text_at - reference_started_at
    )
    gate_passed = (
        reference_payload.get("frames", 0) > 0
        and rendered.shape[-1] > 0
        and all(required_phrases_present.values())
        and not "".join(asr_text).strip()
        and first_model_text_latency is not None
        and first_model_text_latency <= 2.5
    )
    return {
        "schema_version": 1,
        "precision": args.precision,
        "protocol": {
            "input": "continuous zero PCM; no user utterance",
            "warmup_seconds": args.warmup_seconds,
            "capture_seconds": args.capture_seconds,
            "required_phrases": list(REQUIRED_PHRASES),
            "latency_measure": "proactive POST start to first Moshi text token",
            "latency_limit_seconds": 2.5,
        },
        "reference": args.reference,
        "reference_frames": reference_payload.get("frames"),
        "reference_encoding_seconds": (
            reference_completed_at - reference_started_at
        ),
        "first_audio_seconds": first_audio_latency,
        "first_model_text_seconds": first_model_text_latency,
        "marker_text_seconds": marker_text_latency,
        "input_asr": "".join(asr_text).strip(),
        "model_text": "".join(model_text).strip(),
        "streaming_stt_transcript": streaming_stt_transcript,
        "audible_transcript": audible_transcript,
        "required_phrases_present": required_phrases_present,
        "audio_output": str(args.audio_output),
        "audio_sha256": audio_sha256,
        "audio_duration_seconds": rendered.shape[-1] / gate2.SAMPLE_RATE,
        "gate_passed": gate_passed,
    }


async def main() -> int:
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vibetalker-gate3-") as temporary:
        temporary_root = Path(temporary)
        log_root = args.log_dir or temporary_root
        log_root.mkdir(parents=True, exist_ok=True)
        sink = await gate2.start_transcript_sink()
        runtime = gate2.ManagedRuntime(
            args.runtime_root,
            log_root,
            args.precision,
            "model",
        )
        try:
            await runtime.start()
            async with aiohttp.ClientSession() as session:
                result = await run_probe(session, args)
        finally:
            await runtime.stop()
            await sink.cleanup()
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["gate_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
