#!/usr/bin/env python3
"""Exercise app-owned Moshi and pi concurrently for ten speakerless minutes."""

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
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_SITE_PACKAGES = ROOT / "Vendor/voice-runtime/moshi-mlx/site-packages"
if RUNTIME_SITE_PACKAGES.is_dir():
    sys.path.insert(0, str(RUNTIME_SITE_PACKAGES))

import aiohttp
import numpy as np
import sphn


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


soak = load_script(
    "vibetalker_signed_soak_base",
    ROOT / "scripts/run-full-duplex-soak.py",
)
gate1 = soak.gate1
gate2 = soak.gate2
SAMPLE_RATE = soak.SAMPLE_RATE
FRAME_SIZE = soak.FRAME_SIZE
MARKERS = soak.MARKERS
CODING_TASK = (
    "Create a file named signed-duplex-probe.txt containing exactly "
    "signed duplex acceptance, then read it back to verify. "
    "Do not modify any other file."
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--coordinator-url",
        default="http://127.0.0.1:8173",
    )
    parser.add_argument(
        "--moshi-url",
        default="http://127.0.0.1:8999",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Fixtures/Acceptance/signed-pi-duplex-q8.json"),
    )
    parser.add_argument(
        "--audio-output",
        type=Path,
        default=Path("tmp/Acceptance-audio/signed-pi-duplex-q8.wav"),
    )
    parser.add_argument(
        "--prompt-dir",
        type=Path,
        default=Path("tmp/Acceptance-logs/signed-pi-duplex"),
    )
    parser.add_argument("--duration-seconds", type=float, default=600.0)
    parser.add_argument("--prompt-interval-seconds", type=float, default=60.0)
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--speech-rate", type=int, default=185)
    return parser.parse_args()


async def health(session: aiohttp.ClientSession, base_url: str) -> bool:
    try:
        async with session.get(
            f"{base_url}/health",
            timeout=aiohttp.ClientTimeout(total=2),
        ) as response:
            payload = await response.json()
            return response.status == 200 and payload.get("status") == "ready"
    except Exception:
        return False


async def valid_handshake(
    session: aiohttp.ClientSession,
    base_url: str,
) -> aiohttp.ClientWebSocketResponse:
    websocket = await session.ws_connect(
        f"{base_url}/api/chat",
        timeout=aiohttp.ClientWSTimeout(ws_close=5),
        max_msg_size=8 * 1_024 * 1_024,
    )
    handshake = await websocket.receive(timeout=5)
    if (
        handshake.type != aiohttp.WSMsgType.BINARY
        or handshake.data != b"\x00"
    ):
        await websocket.close()
        raise RuntimeError("Moshi returned an invalid WebSocket handshake")
    return websocket


async def commit_transcript(
    session: aiohttp.ClientSession,
    base_url: str,
    transcript: str,
    role: str,
) -> dict[str, Any]:
    utterance_id = str(uuid4())
    started = time.monotonic()
    result: dict[str, Any] = {
        "role": role,
        "utterance_id": utterance_id,
        "transcript": transcript,
    }
    try:
        async with session.post(
            f"{base_url}/v1/transcripts",
            json={
                "utterance_id": utterance_id,
                "revision": 1,
                "transcript": transcript,
                "committed": True,
            },
            timeout=aiohttp.ClientTimeout(total=15),
        ) as response:
            result["status"] = response.status
            result["response"] = await response.json()
            result["accepted"] = (
                response.status == 200
                and result["response"].get("accepted") is True
            )
    except Exception as error:
        result["accepted"] = False
        result["error"] = f"{type(error).__name__}: {error}"
    result["elapsed_seconds"] = time.monotonic() - started
    return result


async def exercise_coordinator(
    session: aiohttp.ClientSession,
    base_url: str,
    started: float,
    duration: float,
) -> list[dict[str, Any]]:
    schedule = [
        (15.0, CODING_TASK, "coding_task"),
        (120.0, "What is the current coding task status?", "status"),
        (300.0, "Give me the grounded status of pi.", "status"),
        (540.0, "Is the signed duplex coding task complete?", "status"),
    ]
    events: list[dict[str, Any]] = []
    for offset, transcript, role in schedule:
        if offset >= duration:
            continue
        remaining = started + offset - time.monotonic()
        if remaining > 0:
            await asyncio.sleep(remaining)
        result = await commit_transcript(
            session,
            base_url,
            transcript,
            role,
        )
        result["scheduled_seconds"] = offset
        result["completed_seconds"] = time.monotonic() - started
        events.append(result)
        print(
            f"coordinator {role}: "
            f"{'accepted' if result['accepted'] else 'failed'}",
            flush=True,
        )
    return events


def percentile(values: list[float], fraction: float) -> float | None:
    return soak.percentile(values, fraction)


async def run(args: argparse.Namespace) -> dict[str, Any]:
    args.prompt_dir.mkdir(parents=True, exist_ok=True)
    prompts = [
        (
            marker,
            gate2.synthesize(
                (
                    f"Moshi, signed duplex marker {marker}. "
                    "Answer briefly and keep listening."
                ),
                args.prompt_dir / f"prompt-{marker}.aiff",
                args.voice,
                args.speech_rate,
            ),
        )
        for marker in MARKERS
    ]
    captured: dict[str, Any] = {}
    prompt_starts: list[dict[str, Any]] = []
    coordinator_events: list[dict[str, Any]] = []
    reconnect_passed = False
    coordinator_ready_before = False
    coordinator_ready_after = False
    started = time.monotonic()

    async with aiohttp.ClientSession() as session:
        coordinator_ready_before = await health(
            session,
            args.coordinator_url,
        )
        if not coordinator_ready_before:
            raise RuntimeError("signed app Coordinator is not ready")
        websocket = await valid_handshake(
            session,
            args.moshi_url,
        )
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
        coordinator_task = asyncio.create_task(exercise_coordinator(
            session,
            args.coordinator_url,
            started,
            args.duration_seconds,
        ))

        for marker, prompt in prompts:
            if time.monotonic() >= stop_at:
                break
            prompt_starts.append({
                "marker": marker,
                "seconds": time.monotonic() - started,
            })
            await gate1.send_pcm(websocket, writer, prompt)
            next_prompt = min(
                stop_at,
                started
                + len(prompt_starts) * args.prompt_interval_seconds,
            )
            silence_seconds = max(0.0, next_prompt - time.monotonic())
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
        coordinator_events = await coordinator_task
        await websocket.close()
        await asyncio.sleep(0.25)
        reconnect = await valid_handshake(
            session,
            args.moshi_url,
        )
        await reconnect.close()
        reconnect_passed = True
        coordinator_ready_after = await health(
            session,
            args.coordinator_url,
        )

    elapsed = time.monotonic() - started
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
    terminal_output_gap = (
        max(0.0, args.duration_seconds - audio_times[-1])
        if audio_times
        else args.duration_seconds
    )
    gap_events = sorted(
        (
            {
                "start_seconds": earlier,
                "end_seconds": later,
                "duration_seconds": later - earlier,
            }
            for earlier, later in zip(audio_times, audio_times[1:])
        ),
        key=lambda event: event["duration_seconds"],
        reverse=True,
    )
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
    coding_events = [
        event for event in coordinator_events
        if event["role"] == "coding_task"
    ]
    status_events = [
        event for event in coordinator_events
        if event["role"] == "status"
    ]
    audio_duration = audio.size / SAMPLE_RATE
    coverage = audio_duration / args.duration_seconds
    checks = {
        "ten_minute_duration": (
            args.duration_seconds >= 600
            and elapsed >= 599
        ),
        "continuous_output_coverage": coverage >= 0.95,
        "no_half_second_output_stall": (
            bool(gaps)
            and max(gaps) < 0.5
            and terminal_output_gap < 0.5
        ),
        "p99_packet_gap_under_150ms": (
            percentile(gaps, 0.99) is not None
            and percentile(gaps, 0.99) < 0.15
        ),
        "local_asr_marker_coverage": len(recognized_markers) >= 8,
        "active_output_interruptions": len(active_interruptions) >= 5,
        "coding_request_accepted": (
            len(coding_events) == 1
            and coding_events[0]["accepted"]
        ),
        "grounded_status_requests_accepted": (
            len(status_events) == 3
            and all(event["accepted"] for event in status_events)
        ),
        "coordinator_remained_ready": (
            coordinator_ready_before and coordinator_ready_after
        ),
        "runtime_remained_connected": reconnect_passed,
    }
    return {
        "schema_version": 1,
        "protocol": {
            "host": "signed Xcode VibeTalker product",
            "transport": "direct WebSocket PCM; no Core Audio output device",
            "precision": "q8",
            "duration_seconds": args.duration_seconds,
            "prompt_interval_seconds": args.prompt_interval_seconds,
            "markers": MARKERS,
            "coding_task": CODING_TASK,
        },
        "elapsed_seconds": elapsed,
        "input_asr": asr,
        "recognized_markers": recognized_markers,
        "prompt_starts": prompt_starts,
        "active_output_interruptions": active_interruptions,
        "coordinator_events": coordinator_events,
        "output_packet_count": len(audio_times),
        "output_audio_duration_seconds": audio_duration,
        "output_coverage": coverage,
        "first_output_packet_seconds": (
            audio_times[0] if audio_times else None
        ),
        "last_output_packet_seconds": (
            audio_times[-1] if audio_times else None
        ),
        "terminal_output_gap_seconds": terminal_output_gap,
        "packet_gap_median_seconds": (
            statistics.median(gaps) if gaps else None
        ),
        "packet_gap_p95_seconds": percentile(gaps, 0.95),
        "packet_gap_p99_seconds": percentile(gaps, 0.99),
        "packet_gap_max_seconds": max(gaps) if gaps else None,
        "largest_packet_gaps": gap_events[:10],
        "half_second_stalls": [
            event for event in gap_events
            if event["duration_seconds"] >= 0.5
        ],
        "audio_output": str(args.audio_output),
        "audio_sha256": audio_sha256,
        "reconnect_passed": reconnect_passed,
        "checks": checks,
        "gate_passed": all(checks.values()),
    }


async def main() -> int:
    args = parse_args()
    result = await run(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({
        "elapsed_seconds": result["elapsed_seconds"],
        "recognized_markers": len(result["recognized_markers"]),
        "accepted_coordinator_events": sum(
            event["accepted"] for event in result["coordinator_events"]
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
