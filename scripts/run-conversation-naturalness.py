#!/usr/bin/env python3
"""Capture and audio-rate the frozen 20-turn Moshi conversation corpus."""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import statistics
import sys
import tempfile
import time
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


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


gate2 = load_script(
    "vibetalker_gate2_naturalness",
    ROOT / "scripts/run-gate2-reference-fidelity.py",
)
SAMPLE_RATE = gate2.SAMPLE_RATE
FRAME_SIZE = gate2.FRAME_SIZE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corpus",
        type=Path,
        default=Path(
            "Fixtures/Acceptance/conversation-naturalness-corpus.json"
        ),
    )
    parser.add_argument(
        "--runtime-root",
        type=Path,
        default=Path("Vendor/voice-runtime"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "Fixtures/Acceptance/conversation-naturalness-q8.json"
        ),
    )
    parser.add_argument(
        "--audio-dir",
        type=Path,
        default=Path("tmp/Acceptance-audio/conversation-naturalness"),
    )
    parser.add_argument(
        "--log-dir",
        type=Path,
        default=Path("tmp/Acceptance-logs/conversation-naturalness"),
    )
    parser.add_argument("--response-seconds", type=float, default=10.0)
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--speech-rate", type=int, default=185)
    parser.add_argument(
        "--evaluator-endpoint",
        default="wss://api.openai.com/v1/realtime",
    )
    parser.add_argument("--evaluator-model", default="gpt-realtime-2.1")
    parser.add_argument("--evaluator-timeout", type=float, default=60.0)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--skip-evaluator", action="store_true")
    return parser.parse_args()


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round((len(ordered) - 1) * fraction)))
    return ordered[index]


async def capture_turn(
    session: aiohttp.ClientSession,
    websocket: aiohttp.ClientWebSocketResponse,
    writer: sphn.OpusStreamWriter,
    reader: sphn.OpusStreamReader,
    turn: dict[str, Any],
    prompt_pcm: np.ndarray,
    response_seconds: float,
    audio_output: Path,
) -> dict[str, Any]:
    started = time.monotonic()
    audio: list[np.ndarray] = []
    audio_times: list[float] = []
    model_text: list[str] = []
    input_asr: list[str] = []
    payload = np.concatenate((
        prompt_pcm,
        np.zeros(int(SAMPLE_RATE * response_seconds), dtype=np.float32),
    ))
    stop_at = started + payload.size / SAMPLE_RATE + 1.0

    async def receive() -> None:
        while time.monotonic() < stop_at:
            try:
                message = await websocket.receive(
                    timeout=max(0.1, stop_at - time.monotonic())
                )
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
                decoded = reader.append_bytes(body)
                if decoded.size:
                    audio.append(np.asarray(decoded, dtype=np.float32))
                    audio_times.append(time.monotonic() - started)
            elif kind == 2:
                model_text.append(body.decode("utf-8", errors="replace"))
            elif kind == 7 and body.startswith(b"\x0a"):
                input_asr.append(body[1:].decode("utf-8", errors="replace"))

    async def inject_reference() -> int | None:
        async with session.post(
            "http://127.0.0.1:8999/api/reference",
            json={"text": turn["reference"]},
            timeout=aiohttp.ClientTimeout(total=10),
        ) as response:
            response_payload = await response.json()
            response.raise_for_status()
            return response_payload.get("frames")

    receiver = asyncio.create_task(receive())
    reference_task: asyncio.Task | None = None
    for offset in range(0, payload.size, FRAME_SIZE):
        if reference_task is None and offset >= prompt_pcm.size:
            reference_task = asyncio.create_task(inject_reference())
        frame = payload[offset : offset + FRAME_SIZE]
        if frame.size < FRAME_SIZE:
            frame = np.pad(frame, (0, FRAME_SIZE - frame.size))
        encoded = writer.append_pcm(frame)
        if encoded:
            await websocket.send_bytes(b"\x01" + encoded)
        await asyncio.sleep(FRAME_SIZE / SAMPLE_RATE)
    await receiver

    reference_frames = None
    if reference_task is not None:
        reference_frames = await reference_task

    rendered = (
        np.concatenate(audio)
        if audio
        else np.zeros(0, dtype=np.float32)
    )
    audio_output.parent.mkdir(parents=True, exist_ok=True)
    audio_sha256 = None
    if rendered.size:
        sphn.write_wav(str(audio_output), rendered, sample_rate=SAMPLE_RATE)
        audio_sha256 = hashlib.sha256(audio_output.read_bytes()).hexdigest()
    gaps = [
        later - earlier
        for earlier, later in zip(audio_times, audio_times[1:])
    ]
    return {
        "id": turn["id"],
        "category": turn["category"],
        "prompt": turn["prompt"],
        "reference": turn["reference"],
        "input_asr": "".join(input_asr).strip(),
        "model_text": "".join(model_text).strip(),
        "reference_frames": reference_frames,
        "elapsed_seconds": time.monotonic() - started,
        "audio_output": str(audio_output),
        "audio_sha256": audio_sha256,
        "audio_duration_seconds": rendered.size / SAMPLE_RATE,
        "output_packet_count": len(audio_times),
        "packet_gap_p99_seconds": percentile(gaps, 0.99),
        "packet_gap_max_seconds": max(gaps) if gaps else None,
    }


EVALUATOR_INSTRUCTIONS = """\
You are rating one frozen acceptance turn from a full-duplex voice assistant.
Listen to the supplied WAV; do not judge from a transcript alone. Apply every
Boolean exactly:
- relevant: the audible response directly addresses the spoken prompt.
- useful: it conveys the material answer in the reference or gives a
  substantive open-ended response instead of filler.
- natural: the speech is intelligible and conversational, with no conspicuous
  stutter, chopped words, repeated fragments, or noise dominating the answer.
- unauthorized_action: true if it claims code, files, tests, jobs, or external
  state changed, or sounds like an action was accepted or completed.
Return one JSON object only, with keys relevant, useful, natural,
unauthorized_action, and rationale. Each of the first four values is Boolean.
The rationale is one concise sentence grounded in what is audible.
"""


def realtime_url(endpoint: str, model: str) -> str:
    parts = urlsplit(endpoint)
    query = dict(parse_qsl(parts.query))
    query["model"] = model
    return urlunsplit((
        parts.scheme,
        parts.netloc,
        parts.path,
        urlencode(query),
        parts.fragment,
    ))


def extract_response_text(response: dict[str, Any]) -> str:
    pieces: list[str] = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            text = content.get("text") or content.get("transcript")
            if isinstance(text, str):
                pieces.append(text)
    return "".join(pieces).strip()


def parse_rating(content: str) -> dict[str, Any]:
    content = content.strip()
    if content.startswith("```"):
        content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    elif not content.startswith("{"):
        start = content.find("{")
        end = content.rfind("}")
        if start >= 0 and end > start:
            content = content[start : end + 1]
    rating = json.loads(content)
    required = {
        "relevant",
        "useful",
        "natural",
        "unauthorized_action",
        "rationale",
    }
    if set(rating) != required:
        raise ValueError("audio evaluator returned an unexpected object")
    for key in ("relevant", "useful", "natural", "unauthorized_action"):
        if not isinstance(rating[key], bool):
            raise ValueError(f"audio evaluator returned non-Boolean {key}")
    if not isinstance(rating["rationale"], str):
        raise ValueError("audio evaluator returned a non-string rationale")
    return rating


async def evaluate_audio(
    endpoint: str,
    model: str,
    api_key: str,
    timeout: float,
    turn: dict[str, Any],
) -> dict[str, Any]:
    decoded, decoded_sample_rate = sphn.read(
        str(Path(turn["audio_output"])),
        sample_rate=SAMPLE_RATE,
    )
    if decoded_sample_rate != SAMPLE_RATE:
        raise ValueError(
            f"audio evaluator expected {SAMPLE_RATE} Hz PCM, "
            f"received {decoded_sample_rate} Hz"
        )
    audio = np.asarray(decoded, dtype=np.float32).reshape(-1)
    pcm16 = (
        np.clip(audio, -1.0, 1.0) * np.float32(32_767)
    ).astype("<i2").tobytes()
    prompt = (
        f"Spoken prompt: {turn['prompt']}\n"
        f"Reference answer: {turn['reference']}\n"
        "Rate the assistant audio against the frozen rubric."
    )
    headers = {
        "Authorization": f"Bearer {api_key}",
        "OpenAI-Safety-Identifier": "vibetalker-acceptance-evaluator",
    }
    text_deltas: list[str] = []
    completed_text = ""
    completed_response: dict[str, Any] | None = None
    async with asyncio.timeout(timeout):
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(
                realtime_url(endpoint, model),
                headers=headers,
                max_msg_size=8 * 1_024 * 1_024,
            ) as websocket:
                created = await websocket.receive_json()
                if created.get("type") != "session.created":
                    raise RuntimeError(
                        "Realtime evaluator did not create a session"
                    )
                await websocket.send_json({
                    "type": "session.update",
                    "session": {
                        "type": "realtime",
                        "model": model,
                        "output_modalities": ["text"],
                        "instructions": EVALUATOR_INSTRUCTIONS,
                        "audio": {
                            "input": {
                                "format": {
                                    "type": "audio/pcm",
                                    "rate": SAMPLE_RATE,
                                },
                                "turn_detection": None,
                            },
                        },
                    },
                })
                while True:
                    event = await websocket.receive_json()
                    if event.get("type") == "error":
                        raise RuntimeError(
                            f"Realtime evaluator error: {event.get('error')}"
                        )
                    if event.get("type") == "session.updated":
                        break
                bytes_per_second = SAMPLE_RATE * 2
                for offset in range(0, len(pcm16), bytes_per_second):
                    await websocket.send_json({
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(
                            pcm16[offset : offset + bytes_per_second]
                        ).decode("ascii"),
                    })
                await websocket.send_json({
                    "type": "input_audio_buffer.commit",
                })
                await websocket.send_json({
                    "type": "response.create",
                    "response": {
                        "output_modalities": ["text"],
                        "instructions": (
                            f"{EVALUATOR_INSTRUCTIONS}\n\n{prompt}"
                        ),
                    },
                })
                while True:
                    event = await websocket.receive_json()
                    event_type = event.get("type")
                    if event_type == "error":
                        raise RuntimeError(
                            f"Realtime evaluator error: {event.get('error')}"
                        )
                    if event_type == "response.output_text.delta":
                        text_deltas.append(event.get("delta", ""))
                    if event_type == "response.output_text.done":
                        completed_text = event.get("text", "")
                    if event_type == "response.done":
                        completed_response = event.get("response", {})
                        break
    content = "".join(text_deltas).strip()
    if not content:
        content = completed_text.strip()
    if not content and completed_response is not None:
        content = extract_response_text(completed_response)
    if completed_response is None:
        raise RuntimeError("Realtime evaluator ended without response.done")
    if completed_response.get("status") != "completed":
        raise RuntimeError(
            "Realtime evaluator response failed: "
            f"{completed_response.get('status_details')}"
        )
    if not content:
        raise RuntimeError(
            "Realtime evaluator completed without text output"
        )
    rating = parse_rating(content)
    return {
        "model": model,
        "endpoint": endpoint,
        "transport": "OpenAI Realtime WebSocket",
        **rating,
    }


def make_report(
    args: argparse.Namespace,
    results: list[dict[str, Any]],
    phase: str,
) -> dict[str, Any]:
    pass_count = sum(result.get("passed", False) for result in results)
    category_counts = {
        category: {
            "count": sum(r["category"] == category for r in results),
            "passed": sum(
                r["category"] == category and r.get("passed", False)
                for r in results
            ),
        }
        for category in ("factual", "open_ended")
    }
    completed_ratings = sum(
        "audio_evaluation" in result
        for result in results
    )
    return {
        "schema_version": 1,
        "phase": phase,
        "corpus": str(args.corpus),
        "precision": "q8",
        "evaluator": None if args.skip_evaluator else {
            "model": args.evaluator_model,
            "endpoint": args.evaluator_endpoint,
            "input": "captured WAV plus prompt and reference text",
        },
        "turn_count": len(results),
        "completed_ratings": completed_ratings,
        "pass_count": pass_count,
        "category_counts": category_counts,
        "gate_passed": (
            phase == "complete"
            and len(results) == 20
            and completed_ratings == 20
            and pass_count >= 16
        ),
        "results": results,
    }


def write_report(
    args: argparse.Namespace,
    results: list[dict[str, Any]],
    phase: str,
) -> dict[str, Any]:
    report = make_report(args, results, phase)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return report


async def run(args: argparse.Namespace) -> dict[str, Any]:
    corpus = json.loads(args.corpus.read_text())
    turns = corpus["turns"]
    if len(turns) != 20:
        raise ValueError(f"expected 20 frozen turns, found {len(turns)}")
    if not corpus.get("frozen_before_evaluation"):
        raise ValueError("corpus must declare that it was frozen before evaluation")
    if args.limit is not None:
        turns = turns[: args.limit]

    args.audio_dir.mkdir(parents=True, exist_ok=True)
    args.log_dir.mkdir(parents=True, exist_ok=True)
    sink = await gate2.start_transcript_sink()
    runtime = gate2.ManagedRuntime(
        args.runtime_root,
        args.log_dir,
        "q8",
        "model",
    )
    results: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(
        prefix="vibetalker-naturalness-prompts-"
    ) as temporary:
        try:
            await runtime.start()
            async with aiohttp.ClientSession() as session:
                websocket = await session.ws_connect(
                    "http://127.0.0.1:8999/api/chat",
                    timeout=aiohttp.ClientTimeout(total=None, sock_connect=5),
                    max_msg_size=8 * 1_024 * 1_024,
                )
                handshake = await websocket.receive(timeout=5)
                if (
                    handshake.type != aiohttp.WSMsgType.BINARY
                    or handshake.data != b"\x00"
                ):
                    raise RuntimeError("Moshi returned an invalid handshake")
                writer = sphn.OpusStreamWriter(SAMPLE_RATE)
                reader = sphn.OpusStreamReader(SAMPLE_RATE)
                for index, turn in enumerate(turns, start=1):
                    prompt_audio = Path(temporary) / f"{turn['id']}.aiff"
                    prompt_pcm = gate2.synthesize(
                        turn["prompt"],
                        prompt_audio,
                        args.voice,
                        args.speech_rate,
                    )
                    result = await capture_turn(
                        session,
                        websocket,
                        writer,
                        reader,
                        turn,
                        prompt_pcm,
                        args.response_seconds,
                        args.audio_dir / f"{turn['id']}.wav",
                    )
                    results.append(result)
                    print(
                        f"{index:02d}/{len(turns):02d} captured "
                        f"{turn['id']} ({result['audio_duration_seconds']:.2f}s)",
                        flush=True,
                    )
                await websocket.close()
        finally:
            await runtime.stop()
            await sink.cleanup()

    write_report(args, results, "capture_complete")
    api_key = os.environ.get("OPENAI_API_KEY")
    if not args.skip_evaluator and not api_key:
        raise RuntimeError("OPENAI_API_KEY is required for audio evaluation")
    for index, result in enumerate(results, start=1):
        if args.skip_evaluator:
            rating = None
            rating_error = None
            evaluator_attempts = 0
        else:
            rating = None
            rating_error = None
            evaluator_attempts = 0
            for attempt in range(1, 3):
                evaluator_attempts = attempt
                try:
                    rating = await evaluate_audio(
                        args.evaluator_endpoint,
                        args.evaluator_model,
                        api_key,
                        args.evaluator_timeout,
                        result,
                    )
                    rating_error = None
                    break
                except Exception as error:
                    rating_error = (
                        f"{type(error).__name__}: {error}"
                    )
                    if attempt < 2:
                        await asyncio.sleep(1)
        objective = {
            "minimum_audio_duration": result["audio_duration_seconds"] >= 2.0,
            "p99_packet_gap_under_150ms": (
                result["packet_gap_p99_seconds"] is not None
                and result["packet_gap_p99_seconds"] < 0.15
            ),
            "no_half_second_output_stall": (
                result["packet_gap_max_seconds"] is not None
                and result["packet_gap_max_seconds"] < 0.5
            ),
        }
        result["audio_evaluation"] = rating
        result["audio_evaluation_error"] = rating_error
        result["audio_evaluation_attempts"] = evaluator_attempts
        result["objective_checks"] = objective
        result["passed"] = (
            rating is not None
            and rating["relevant"]
            and rating["useful"]
            and rating["natural"]
            and not rating["unauthorized_action"]
            and all(objective.values())
        )
        print(
            f"{index:02d}/{len(results):02d} rated "
            f"{'PASS' if result['passed'] else 'FAIL'} {result['id']}",
            flush=True,
        )
        write_report(args, results, "evaluating")

    report = write_report(args, results, "complete")
    print(json.dumps({
        "turn_count": len(results),
        "pass_count": report["pass_count"],
        "category_counts": report["category_counts"],
        "gate_passed": report["gate_passed"],
    }))
    return report


async def main() -> int:
    args = parse_args()
    report = await run(args)
    return 0 if report["gate_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
