#!/usr/bin/env python3
"""Exercise the accepted Apple-Silicon Moshi-RAG topology end to end."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
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


GATE2_PATH = ROOT / "scripts/run-gate2-reference-fidelity.py"
SPEC = importlib.util.spec_from_file_location("vibetalker_gate2", GATE2_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {GATE2_PATH}")
gate2 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate2)

SAMPLE_RATE = gate2.SAMPLE_RATE
FRAME_SIZE = gate2.FRAME_SIZE


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
        default=Path("Fixtures/Gate1/results/optimized-topology-bf16.json"),
    )
    parser.add_argument(
        "--audio-output",
        type=Path,
        default=Path("tmp/Gate1-audio/barge-in-response.wav"),
    )
    parser.add_argument("--precision", choices=("bf16", "q8"), default="bf16")
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--speech-rate", type=int, default=185)
    parser.add_argument("--capture-seconds", type=float, default=14.0)
    return parser.parse_args()


class TranscriptRecorder:
    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []

    async def handle(self, request: web.Request) -> web.Response:
        payload = await request.json()
        self.requests.append({
            **payload,
            "received_at": time.monotonic(),
        })
        return web.json_response({"accepted": True})

    async def start(self) -> web.AppRunner:
        app = web.Application()
        app.router.add_post("/transcripts", self.handle)
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", 8174).start()
        return runner


async def send_pcm(
    websocket: aiohttp.ClientWebSocketResponse,
    writer: sphn.OpusStreamWriter,
    pcm: np.ndarray,
) -> None:
    for offset in range(0, pcm.shape[-1], FRAME_SIZE):
        frame = pcm[offset : offset + FRAME_SIZE]
        if frame.shape[-1] < FRAME_SIZE:
            frame = np.pad(frame, (0, FRAME_SIZE - frame.shape[-1]))
        encoded = writer.append_pcm(frame)
        if encoded:
            await websocket.send_bytes(b"\x01" + encoded)
        await asyncio.sleep(FRAME_SIZE / SAMPLE_RATE)


async def receive_output(
    websocket: aiohttp.ClientWebSocketResponse,
    reader: sphn.OpusStreamReader,
    first_audio: asyncio.Event,
    stop_at: float,
    started: float,
) -> dict[str, Any]:
    audio: list[np.ndarray] = []
    text: list[str] = []
    asr: list[str] = []
    audio_times: list[float] = []
    ret_times: list[float] = []
    while time.monotonic() < stop_at:
        try:
            message = await websocket.receive(
                timeout=max(0.1, stop_at - time.monotonic())
            )
        except TimeoutError:
            break
        if message.type != aiohttp.WSMsgType.BINARY:
            if message.type in {
                aiohttp.WSMsgType.CLOSE,
                aiohttp.WSMsgType.CLOSED,
                aiohttp.WSMsgType.ERROR,
            }:
                break
            continue
        data = message.data
        if not data:
            continue
        kind, body = data[0], data[1:]
        elapsed = time.monotonic() - started
        if kind == 1:
            decoded = reader.append_bytes(body)
            if decoded.shape[-1]:
                audio.append(np.asarray(decoded, dtype=np.float32))
                audio_times.append(elapsed)
                first_audio.set()
        elif kind == 2:
            token = body.decode("utf-8", errors="replace")
            text.append(token)
            if token == "[RET]":
                ret_times.append(elapsed)
        elif kind == 7 and body.startswith(b"\x0a"):
            asr.append(body[1:].decode("utf-8", errors="replace"))
    return {
        "audio": audio,
        "audio_times": audio_times,
        "text": text,
        "asr": asr,
        "ret_times": ret_times,
    }


async def valid_handshake(
    session: aiohttp.ClientSession,
) -> aiohttp.ClientWebSocketResponse:
    websocket = await session.ws_connect(
        "http://127.0.0.1:8999/api/chat",
        timeout=aiohttp.ClientTimeout(total=None, sock_connect=5),
        max_msg_size=8 * 1_024 * 1_024,
    )
    handshake = await websocket.receive(timeout=5)
    if handshake.type != aiohttp.WSMsgType.BINARY or handshake.data != b"\x00":
        await websocket.close()
        raise RuntimeError("Moshi returned an invalid WebSocket handshake")
    return websocket


async def run_fixture(args: argparse.Namespace) -> dict[str, Any]:
    prompt_one = "Moshi, the first verification word is canyon."
    prompt_two = "Interrupting now. Tell me the verification word lantern."
    with tempfile.TemporaryDirectory(prefix="vibetalker-gate1-") as temporary:
        temporary_root = Path(temporary)
        prompt_one_pcm = gate2.synthesize(
            prompt_one,
            temporary_root / "prompt-one.aiff",
            args.voice,
            args.speech_rate,
        )
        prompt_two_pcm = gate2.synthesize(
            prompt_two,
            temporary_root / "prompt-two.aiff",
            args.voice,
            args.speech_rate,
        )
        recorder = TranscriptRecorder()
        sink = await recorder.start()
        runtime = gate2.ManagedRuntime(
            args.runtime_root,
            temporary_root,
            args.precision,
            "model",
        )
        try:
            await runtime.start()
            async with aiohttp.ClientSession() as session:
                websocket = await valid_handshake(session)
                writer = sphn.OpusStreamWriter(SAMPLE_RATE)
                reader = sphn.OpusStreamReader(SAMPLE_RATE)
                started = time.monotonic()
                stop_at = started + args.capture_seconds
                first_audio = asyncio.Event()
                receiver = asyncio.create_task(receive_output(
                    websocket,
                    reader,
                    first_audio,
                    stop_at,
                    started,
                ))
                await send_pcm(websocket, writer, prompt_one_pcm)
                await send_pcm(
                    websocket,
                    writer,
                    np.zeros(SAMPLE_RATE, dtype=np.float32),
                )
                try:
                    await asyncio.wait_for(first_audio.wait(), timeout=6)
                except TimeoutError:
                    pass
                interruption_started = time.monotonic() - started
                await send_pcm(websocket, writer, prompt_two_pcm)
                silence_seconds = max(
                    0.0,
                    stop_at - time.monotonic() - 0.2,
                )
                await send_pcm(
                    websocket,
                    writer,
                    np.zeros(
                        int(SAMPLE_RATE * silence_seconds),
                        dtype=np.float32,
                    ),
                )
                captured = await receiver
                await websocket.close()

                # The runtime serializes sessions; wait for cleanup before proving
                # that reconnect does not require a process restart.
                await asyncio.sleep(0.25)
                reconnect = await valid_handshake(session)
                await reconnect.close()
                reconnect_passed = True
        finally:
            await runtime.stop()
            await sink.cleanup()

        moshi_log = (temporary_root / "moshi.log").read_text(errors="replace")

    rendered = (
        np.concatenate(captured["audio"])
        if captured["audio"]
        else np.zeros(0, dtype=np.float32)
    )
    audio_sha256 = None
    if rendered.size:
        args.audio_output.parent.mkdir(parents=True, exist_ok=True)
        sphn.write_wav(
            str(args.audio_output),
            rendered,
            sample_rate=SAMPLE_RATE,
        )
        audio_sha256 = hashlib.sha256(args.audio_output.read_bytes()).hexdigest()

    asr = "".join(captured["asr"]).strip()
    model_text = "".join(captured["text"]).strip()
    normalized_asr = asr.lower()
    unique_request_ids = {
        request["utterance_id"] for request in recorder.requests
    }
    duplicate_posts = len(recorder.requests) - len(unique_request_ids)
    audio_before_interruption = any(
        timestamp < interruption_started
        for timestamp in captured["audio_times"]
    )
    audio_after_interruption = any(
        timestamp > interruption_started
        for timestamp in captured["audio_times"]
    )
    ret_count = len(captured["ret_times"])
    reconciled_count = moshi_log.count("reconciled retrieval trigger")
    reused_count = moshi_log.count("reused ASR utterance")
    checks = {
        "local_asr_first_utterance": "canyon" in normalized_asr,
        "local_asr_barge_in": (
            "interrupt" in normalized_asr
            and "lantern" in normalized_asr
        ),
        "model_audio_before_barge_in": audio_before_interruption,
        "model_audio_after_barge_in": audio_after_interruption,
        "retrieval_token_observed": ret_count > 0,
        "retrieval_reconciled": reconciled_count > 0,
        "no_duplicate_transcript_posts": duplicate_posts == 0,
        "reconnect_without_restart": reconnect_passed,
    }
    return {
        "schema_version": 1,
        "precision": args.precision,
        "protocol": {
            "transport": "direct WebSocket PCM; no Core Audio output device",
            "first_prompt": prompt_one,
            "barge_in_prompt": prompt_two,
            "capture_seconds": args.capture_seconds,
        },
        "asr": asr,
        "model_text": model_text,
        "interruption_started_seconds": interruption_started,
        "first_audio_seconds": (
            captured["audio_times"][0] if captured["audio_times"] else None
        ),
        "last_audio_seconds": (
            captured["audio_times"][-1] if captured["audio_times"] else None
        ),
        "retrieval_token_seconds": captured["ret_times"],
        "transcript_requests": recorder.requests,
        "duplicate_transcript_posts": duplicate_posts,
        "retrieval_reconciliations": reconciled_count,
        "retrieval_reuses": reused_count,
        "audio_output": str(args.audio_output),
        "audio_sha256": audio_sha256,
        "audio_duration_seconds": rendered.size / SAMPLE_RATE,
        "checks": checks,
        "gate_passed": all(checks.values()),
    }


async def main() -> int:
    args = parse_args()
    result = await run_fixture(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({
        "asr": result["asr"],
        "retrieval_tokens": len(result["retrieval_token_seconds"]),
        "checks": result["checks"],
        "gate_passed": result["gate_passed"],
    }))
    return 0 if result["gate_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
