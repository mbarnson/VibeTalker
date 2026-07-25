#!/usr/bin/env python3
"""Run a ten-minute active-output soak against the pinned local voice runtime."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import sys
import time
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_SITE_PACKAGES = ROOT / "Vendor/voice-runtime/moshi-mlx/site-packages"
if RUNTIME_SITE_PACKAGES.is_dir():
    sys.path.insert(0, str(RUNTIME_SITE_PACKAGES))

import aiohttp
import numpy as np
import sphn
from aiohttp import web


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate1 = load_script(
    "vibetalker_gate1",
    ROOT / "scripts/run-gate1-optimized-topology.py",
)
gate2 = gate1.gate2
SAMPLE_RATE = gate2.SAMPLE_RATE
FRAME_SIZE = gate2.FRAME_SIZE
MARKERS = [
    "canyon",
    "lantern",
    "orchard",
    "velvet",
    "copper",
    "meadow",
    "harbor",
    "comet",
    "willow",
    "cobalt",
]


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
        default=Path("Fixtures/Acceptance/full-duplex-soak-q8.json"),
    )
    parser.add_argument(
        "--audio-output",
        type=Path,
        default=Path("tmp/Acceptance-audio/full-duplex-soak-q8.wav"),
    )
    parser.add_argument(
        "--log-dir",
        type=Path,
        default=Path("tmp/Acceptance-logs/full-duplex-soak"),
        help="Persistent runtime logs retained after both passing and failed runs.",
    )
    parser.add_argument("--duration-seconds", type=float, default=600.0)
    parser.add_argument("--prompt-interval-seconds", type=float, default=60.0)
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--speech-rate", type=int, default=185)
    return parser.parse_args()


class ReferenceRecorder:
    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []

    async def handle(self, request: web.Request) -> web.Response:
        payload = await request.json()
        transcript = str(payload.get("transcript", ""))
        marker = next(
            (candidate for candidate in MARKERS if candidate in transcript.lower()),
            "realtime",
        )
        reference = (
            "Answer briefly. Include the verification marker "
            f"{marker}. Keep the conversation responsive."
        )
        started = time.monotonic()
        accepted = False
        frames = None
        error = None
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    "http://127.0.0.1:8999/api/reference",
                    json={"text": reference},
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as response:
                    response_payload = await response.json()
                    response.raise_for_status()
                    accepted = bool(response_payload.get("accepted"))
                    frames = response_payload.get("frames")
        except Exception as exception:
            error = str(exception)
        self.requests.append({
            "utterance_id": payload.get("utterance_id"),
            "transcript": transcript,
            "marker": marker,
            "accepted": accepted,
            "frames": frames,
            "elapsed_seconds": time.monotonic() - started,
            "error": error,
        })
        status = 200 if accepted else 503
        return web.json_response({"accepted": accepted}, status=status)

    async def start(self) -> web.AppRunner:
        app = web.Application()
        app.router.add_post("/transcripts", self.handle)
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", 8174).start()
        return runner


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round((len(ordered) - 1) * fraction)))
    return ordered[index]


async def run_soak(args: argparse.Namespace) -> dict[str, Any]:
    log_root = args.log_dir.resolve()
    log_root.mkdir(parents=True, exist_ok=True)
    prompts = [
        (
            marker,
            gate2.synthesize(
                (
                    f"Moshi, soak marker {marker}. "
                    "Give one short sentence about real time audio."
                ),
                log_root / f"prompt-{marker}.aiff",
                args.voice,
                args.speech_rate,
            ),
        )
        for marker in MARKERS
    ]
    references = ReferenceRecorder()
    sink = await references.start()
    runtime = gate2.ManagedRuntime(
        args.runtime_root,
        log_root,
        "q8",
        "model",
    )
    captured: dict[str, Any] = {}
    prompt_starts: list[dict[str, Any]] = []
    reconnect_passed = False
    started = time.monotonic()
    try:
        await runtime.start()
        async with aiohttp.ClientSession() as session:
            websocket = await gate1.valid_handshake(session)
            writer = sphn.OpusStreamWriter(SAMPLE_RATE)
            reader = sphn.OpusStreamReader(SAMPLE_RATE)
            started = time.monotonic()
            stop_at = started + args.duration_seconds
            first_audio = asyncio.Event()
            receiver = asyncio.create_task(gate1.receive_output(
                websocket,
                reader,
                first_audio,
                stop_at,
                started,
            ))

            for marker, prompt in prompts:
                if time.monotonic() >= stop_at:
                    break
                prompt_started = time.monotonic() - started
                prompt_starts.append({
                    "marker": marker,
                    "seconds": prompt_started,
                })
                await gate1.send_pcm(websocket, writer, prompt)
                next_prompt = min(
                    stop_at,
                    started
                    + len(prompt_starts) * args.prompt_interval_seconds,
                )
                silence_seconds = max(
                    0.0,
                    next_prompt - time.monotonic(),
                )
                await gate1.send_pcm(
                    websocket,
                    writer,
                    np.zeros(
                        int(SAMPLE_RATE * silence_seconds),
                        dtype=np.float32,
                    ),
                )

            remaining = max(0.0, stop_at - time.monotonic())
            if remaining:
                await gate1.send_pcm(
                    websocket,
                    writer,
                    np.zeros(
                        int(SAMPLE_RATE * remaining),
                        dtype=np.float32,
                    ),
                )
            captured = await receiver
            await websocket.close()
            await asyncio.sleep(0.25)
            reconnect = await gate1.valid_handshake(session)
            await reconnect.close()
            reconnect_passed = True
    finally:
        await runtime.stop()
        await sink.cleanup()
    elapsed = time.monotonic() - started
    moshi_log = (log_root / "moshi.log").read_text(errors="replace")

    audio = (
        np.concatenate(captured["audio"])
        if captured.get("audio")
        else np.zeros(0, dtype=np.float32)
    )
    args.audio_output.parent.mkdir(parents=True, exist_ok=True)
    audio_sha256 = None
    if audio.size:
        sphn.write_wav(
            str(args.audio_output),
            audio,
            sample_rate=SAMPLE_RATE,
        )
        audio_sha256 = hashlib.sha256(
            args.audio_output.read_bytes()
        ).hexdigest()

    audio_times = captured.get("audio_times", [])
    gaps = [
        later - earlier
        for earlier, later in zip(audio_times, audio_times[1:])
    ]
    asr = "".join(captured.get("asr", [])).strip()
    normalized_asr = asr.lower()
    recognized_markers = [
        marker for marker in MARKERS if marker in normalized_asr
    ]
    active_interruptions = [
        prompt
        for prompt in prompt_starts[1:]
        if any(
            0 < prompt["seconds"] - audio_time <= 0.5
            for audio_time in audio_times
        )
    ]
    accepted_references = [
        request for request in references.requests if request["accepted"]
    ]
    audio_duration = audio.size / SAMPLE_RATE
    coverage = audio_duration / args.duration_seconds
    checks = {
        "ten_minute_duration": (
            args.duration_seconds >= 600
            and elapsed >= 599
        ),
        "continuous_output_coverage": coverage >= 0.95,
        "no_half_second_output_stall": bool(gaps) and max(gaps) < 0.5,
        "p99_packet_gap_under_150ms": (
            percentile(gaps, 0.99) is not None
            and percentile(gaps, 0.99) < 0.15
        ),
        "local_asr_marker_coverage": len(recognized_markers) >= 8,
        "active_output_interruptions": len(active_interruptions) >= 5,
        "dynamic_reference_injection": len(accepted_references) >= 8,
        "runtime_remained_connected": reconnect_passed,
    }
    return {
        "schema_version": 1,
        "protocol": {
            "transport": "direct WebSocket PCM; no Core Audio output device",
            "precision": "q8",
            "duration_seconds": args.duration_seconds,
            "prompt_interval_seconds": args.prompt_interval_seconds,
            "markers": MARKERS,
        },
        "elapsed_seconds": elapsed,
        "input_asr": asr,
        "recognized_markers": recognized_markers,
        "prompt_starts": prompt_starts,
        "active_output_interruptions": active_interruptions,
        "reference_requests": references.requests,
        "retrieval_token_count": len(captured.get("ret_times", [])),
        "retrieval_reconciliations": moshi_log.count(
            "reconciled retrieval trigger"
        ),
        "output_packet_count": len(audio_times),
        "output_audio_duration_seconds": audio_duration,
        "output_coverage": coverage,
        "packet_gap_median_seconds": (
            statistics.median(gaps) if gaps else None
        ),
        "packet_gap_p95_seconds": percentile(gaps, 0.95),
        "packet_gap_p99_seconds": percentile(gaps, 0.99),
        "packet_gap_max_seconds": max(gaps) if gaps else None,
        "audio_output": str(args.audio_output),
        "audio_sha256": audio_sha256,
        "reconnect_passed": reconnect_passed,
        "checks": checks,
        "gate_passed": all(checks.values()),
    }


async def main() -> int:
    args = parse_args()
    result = await run_soak(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({
        "elapsed_seconds": result["elapsed_seconds"],
        "recognized_markers": len(result["recognized_markers"]),
        "accepted_references": sum(
            request["accepted"] for request in result["reference_requests"]
        ),
        "output_coverage": result["output_coverage"],
        "packet_gap_p99_seconds": result["packet_gap_p99_seconds"],
        "packet_gap_max_seconds": result["packet_gap_max_seconds"],
        "checks": result["checks"],
        "gate_passed": result["gate_passed"],
    }))
    return 0 if result["gate_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
