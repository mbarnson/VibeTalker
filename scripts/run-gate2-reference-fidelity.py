#!/usr/bin/env python3
"""Run the frozen Gate 2 Reference-fidelity corpus against local Moshi."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any

RUNTIME_SITE_PACKAGES = (
    Path(__file__).resolve().parents[1]
    / "Vendor/voice-runtime/moshi-mlx/site-packages"
)
if RUNTIME_SITE_PACKAGES.is_dir():
    sys.path.insert(0, str(RUNTIME_SITE_PACKAGES))

import aiohttp
import msgpack
import numpy as np
import sphn


SAMPLE_RATE = 24_000
FRAME_SIZE = 1_920
WHISPER_PACKAGE = "mlx-whisper==0.4.3"
WHISPER_MODEL_REVISION = "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corpus",
        type=Path,
        default=Path("Fixtures/Gate2/reference-fidelity-corpus.json"),
    )
    parser.add_argument(
        "--runtime-root",
        type=Path,
        default=Path("Vendor/voice-runtime"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Fixtures/Gate2/results/reference-fidelity.json"),
    )
    parser.add_argument("--log-dir", type=Path)
    parser.add_argument(
        "--audio-dir",
        type=Path,
        default=Path("tmp/Gate2-audio"),
    )
    parser.add_argument("--run", choices=("run-1", "run-2"))
    parser.add_argument("--limit", type=int)
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--speech-rate", type=int, default=185)
    parser.add_argument("--response-seconds", type=float, default=12.0)
    parser.add_argument("--precision", choices=("bf16", "q8"), default="bf16")
    parser.add_argument(
        "--first-speaker",
        choices=("model", "user"),
        default="model",
        help="Moshi-RAG prepend condition; upstream defaults to model.",
    )
    parser.add_argument("--skip-reference", action="store_true")
    parser.add_argument(
        "--whisper-model",
        default="mlx-community/whisper-small-mlx",
    )
    parser.add_argument("--skip-whisper", action="store_true")
    parser.add_argument("--keep-runtime", action="store_true")
    return parser.parse_args()


def normalized(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def score(turn: dict[str, Any], response: str) -> str:
    value = normalized(response)
    if any(normalized(phrase) in value for phrase in turn["forbidden_phrases"]):
        return "contradiction"
    if all(normalized(phrase) in value for phrase in turn["required_phrases"]):
        return "fully_correct"
    return "partial"


def runtime_environment(runtime_root: Path, package: str) -> dict[str, str]:
    runtime_root = runtime_root.resolve()
    environment = {
        "HOME": str(Path.home()),
        "HF_HOME": str(runtime_root / "HuggingFace"),
        "NO_PROXY": "127.0.0.1,localhost",
        "PATH": "/usr/bin:/bin",
        "PYTHONHOME": str(runtime_root / "Python"),
        "PYTHONNOUSERSITE": "1",
        "PYTHONUNBUFFERED": "1",
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "TMPDIR": tempfile.gettempdir(),
        "PYTHONPATH": str(runtime_root / package / "site-packages"),
    }
    return environment


class ManagedRuntime:
    def __init__(
        self,
        runtime_root: Path,
        log_root: Path,
        precision: str,
        first_speaker: str,
    ):
        self.root = runtime_root.resolve()
        self.log_root = log_root
        self.precision = precision
        self.first_speaker = first_speaker
        self.processes: list[tuple[str, asyncio.subprocess.Process, Any]] = []

    async def start(self) -> None:
        python = self.root / "Python/bin/python3.12"
        models = self.root / "Models"
        await self._spawn(
            "reference-encoder",
            [
                str(python),
                "-m",
                "moshi.server_conditioner",
                "--moshi-weight",
                str(models / "moshika-rag-pytorch-bf16.safetensors"),
                "--config",
                str(self.root / "moshi-rag-config.json"),
                "--conditioner",
                "reference_with_time",
                "--cuda-device",
                "mps",
                "--host",
                "127.0.0.1",
                "--port",
                "8001",
            ],
            runtime_environment(self.root, "moshi-rag"),
            self.root,
        )
        await self._spawn(
            "speech-to-text",
            [
                str(self.root / "Bin/vibetalker-stt"),
                "worker",
                "--addr",
                "127.0.0.1",
                "--port",
                "8997",
                "--cpu",
                "--silent",
                "--config",
                str(self.root / "moshi-stt.toml"),
            ],
            {
                **runtime_environment(self.root, "moshi-mlx"),
                "RAYON_NUM_THREADS": "4",
                "VECLIB_MAXIMUM_THREADS": "4",
            },
            self.root,
        )
        moshi_arguments = [str(python), "-m", "moshi_mlx.local_web"]
        if self.precision == "q8":
            moshi_arguments.extend(["--quantized", "8"])
        moshi_arguments.extend(
            [
                "--moshi-weight",
                str(models / (
                    "moshika-rag-mlx-q8.safetensors"
                    if self.precision == "q8"
                    else "moshika-rag-mlx-bf16.safetensors"
                )),
                "--tokenizer",
                str(models / "tokenizer_spm_32k_3.model"),
                "--mimi-weight",
                str(models / "tokenizer-e351c8d8-checkpoint125.safetensors"),
                "--lm-config",
                str(self.root / "moshi-rag-mlx-config.json"),
                "--first-speaker",
                self.first_speaker,
                "--host",
                "127.0.0.1",
                "--port",
                "8999",
                "--static",
                "none",
                "--no-browser",
                "--stt-url",
                "ws://127.0.0.1:8997/api/asr_streaming?auth_id=loopback-only",
                "--transcript-url",
                "http://127.0.0.1:8174/transcripts",
            ]
        )
        await self._spawn(
            "moshi",
            moshi_arguments,
            runtime_environment(self.root, "moshi-mlx"),
            self.root / "moshi-mlx",
        )
        await self._wait_for_url("http://127.0.0.1:8001/docs", 60)
        await self._wait_for_url("http://127.0.0.1:8997/api/build_info", 60)
        await self._wait_for_port("127.0.0.1", 8999, 60)

    async def _spawn(
        self,
        name: str,
        command: list[str],
        environment: dict[str, str],
        cwd: Path,
    ) -> None:
        log = (self.log_root / f"{name}.log").open("wb")
        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=cwd,
            env=environment,
            stdout=log,
            stderr=asyncio.subprocess.STDOUT,
            start_new_session=True,
        )
        self.processes.append((name, process, log))

    async def _wait_for_url(self, url: str, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        async with aiohttp.ClientSession() as session:
            while time.monotonic() < deadline:
                try:
                    async with session.get(
                        url, timeout=aiohttp.ClientTimeout(total=1)
                    ) as response:
                        if response.status < 500:
                            return
                except (aiohttp.ClientError, TimeoutError):
                    pass
                self._assert_running()
                await asyncio.sleep(0.2)
        raise TimeoutError(f"runtime readiness timed out: {url}")

    async def _wait_for_port(self, host: str, port: int, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                _, writer = await asyncio.open_connection(host, port)
                writer.close()
                await writer.wait_closed()
                return
            except OSError:
                self._assert_running()
                await asyncio.sleep(0.2)
        raise TimeoutError(f"runtime readiness timed out: {host}:{port}")

    def _assert_running(self) -> None:
        for name, process, _ in self.processes:
            if process.returncode is not None:
                raise RuntimeError(f"{name} exited with status {process.returncode}")

    async def stop(self) -> None:
        for _, process, _ in reversed(self.processes):
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for _, process, log in reversed(self.processes):
            if process.returncode is None:
                try:
                    await asyncio.wait_for(process.wait(), timeout=5)
                except TimeoutError:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    await process.wait()
            log.close()
        self.processes.clear()


async def transcript_sink(request: aiohttp.web.Request) -> aiohttp.web.Response:
    await request.read()
    return aiohttp.web.json_response({"accepted": True})


async def start_transcript_sink() -> aiohttp.web.AppRunner:
    from aiohttp import web

    app = web.Application()
    app.router.add_post("/transcripts", transcript_sink)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", 8174).start()
    return runner


def synthesize(prompt: str, output: Path, voice: str, rate: int) -> np.ndarray:
    subprocess.run(
        ["/usr/bin/say", "-v", voice, "-r", str(rate), "-o", str(output), prompt],
        check=True,
    )
    pcm, _ = sphn.read(str(output), sample_rate=SAMPLE_RATE)
    return np.asarray(pcm[0], dtype=np.float32)


async def run_turn(
    session: aiohttp.ClientSession,
    websocket: aiohttp.ClientWebSocketResponse,
    opus_writer: sphn.OpusStreamWriter,
    opus_reader: sphn.OpusStreamReader,
    turn: dict[str, Any],
    audio: np.ndarray,
    response_seconds: float,
    audio_output: Path,
    whisper_model: str | None,
) -> dict[str, Any]:
    started = time.monotonic()
    async def inject_reference() -> dict[str, Any]:
        async with session.post(
            "http://127.0.0.1:8999/api/reference",
            json={"text": turn["reference"]},
            timeout=aiohttp.ClientTimeout(total=10),
        ) as response:
            reference_payload = await response.json()
            response.raise_for_status()
            return reference_payload

    output_pcm: list[np.ndarray] = []
    model_text: list[str] = []
    asr_text: list[str] = []
    silence = np.zeros(
        int(SAMPLE_RATE * response_seconds),
        dtype=np.float32,
    )
    payload = np.concatenate((audio, silence))
    capture_seconds = payload.shape[-1] / SAMPLE_RATE + 1

    async def receive() -> None:
        deadline = time.monotonic() + capture_seconds
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
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
                if decoded.shape[-1] > 0:
                    output_pcm.append(np.asarray(decoded, dtype=np.float32))
            elif kind == 2:
                model_text.append(body.decode("utf-8", errors="replace"))
            elif kind == 7 and body.startswith(b"\x0a"):
                asr_text.append(body[1:].decode("utf-8", errors="replace"))

    receiver = asyncio.create_task(receive())
    reference_task: asyncio.Task[dict[str, Any]] | None = None
    for offset in range(0, payload.shape[-1], FRAME_SIZE):
        if (
            reference_task is None
            and turn["reference"]
            and offset >= audio.shape[-1]
        ):
            reference_task = asyncio.create_task(inject_reference())
        frame = payload[offset : offset + FRAME_SIZE]
        if frame.shape[-1] < FRAME_SIZE:
            frame = np.pad(frame, (0, FRAME_SIZE - frame.shape[-1]))
        encoded = opus_writer.append_pcm(frame)
        if encoded:
            await websocket.send_bytes(b"\x01" + encoded)
        await asyncio.sleep(FRAME_SIZE / SAMPLE_RATE)
    await receiver
    reference_payload = (
        await reference_task
        if reference_task is not None
        else {}
    )

    streaming_stt_transcript = ""
    audible_transcript = ""
    audio_sha256 = None
    audio_duration_seconds = 0.0
    if output_pcm:
        rendered = np.concatenate(output_pcm)
        sphn.write_wav(str(audio_output), rendered, sample_rate=SAMPLE_RATE)
        streaming_stt_transcript = await transcribe_pcm(session, rendered)
        audio_sha256 = hashlib.sha256(audio_output.read_bytes()).hexdigest()
        audio_duration_seconds = rendered.shape[-1] / SAMPLE_RATE
        if whisper_model is not None:
            audible_transcript = transcribe_with_whisper(
                audio_output,
                whisper_model,
            )
        else:
            audible_transcript = streaming_stt_transcript
    model_response_text = "".join(model_text).strip()
    scored_response = audible_transcript or model_response_text
    return {
        "id": turn["id"],
        "reference": turn["reference"],
        "prompt": turn["prompt"],
        "reference_frames": reference_payload.get("frames"),
        "asr": "".join(asr_text).strip(),
        "model_text": model_response_text,
        "streaming_stt_transcript": streaming_stt_transcript,
        "audible_transcript": audible_transcript,
        "response": scored_response,
        "score": score(turn, scored_response),
        "elapsed_seconds": time.monotonic() - started,
        "audio_output": str(audio_output),
        "audio_sha256": audio_sha256,
        "audio_duration_seconds": audio_duration_seconds,
    }


async def transcribe_pcm(
    session: aiohttp.ClientSession,
    pcm: np.ndarray,
) -> str:
    words: list[str] = []
    async with session.ws_connect(
        "ws://127.0.0.1:8997/api/asr_streaming?auth_id=loopback-only",
        timeout=aiohttp.ClientTimeout(total=None, sock_connect=5),
        max_msg_size=8 * 1_024 * 1_024,
    ) as websocket:
        async def receive() -> None:
            while True:
                message = await websocket.receive()
                if message.type != aiohttp.WSMsgType.BINARY:
                    if message.type in {
                        aiohttp.WSMsgType.CLOSE,
                        aiohttp.WSMsgType.CLOSED,
                        aiohttp.WSMsgType.ERROR,
                    }:
                        return
                    continue
                event = msgpack.unpackb(message.data, raw=False)
                if event.get("type") == "Word":
                    text = event.get("text", "")
                    if isinstance(text, str) and text:
                        words.append(text.rstrip() + " ")

        receiver = asyncio.create_task(receive())
        silence = np.zeros(SAMPLE_RATE * 2, dtype=np.float32)
        payload = np.concatenate((pcm, silence))
        for offset in range(0, payload.shape[-1], FRAME_SIZE):
            frame = payload[offset : offset + FRAME_SIZE]
            if frame.shape[-1] < FRAME_SIZE:
                frame = np.pad(frame, (0, FRAME_SIZE - frame.shape[-1]))
            await websocket.send_bytes(msgpack.packb(
                {"type": "Audio", "pcm": frame.tolist()},
                use_bin_type=True,
                use_single_float=True,
            ))
            await asyncio.sleep(FRAME_SIZE / SAMPLE_RATE)
        await asyncio.sleep(1)
        await websocket.close()
        await receiver
    return "".join(words).strip()


def transcribe_with_whisper(audio: Path, model: str) -> str:
    with tempfile.TemporaryDirectory(
        prefix="vibetalker-gate2-whisper-"
    ) as output:
        subprocess.run(
            [
                "uvx",
                "--from",
                WHISPER_PACKAGE,
                "mlx_whisper",
                str(audio),
                "--model",
                model,
                "--language",
                "en",
                "--output-dir",
                output,
                "--output-format",
                "txt",
                "--verbose",
                "False",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        transcript = Path(output) / f"{audio.stem}.txt"
        return transcript.read_text().strip()


async def main() -> int:
    args = parse_args()
    corpus = json.loads(args.corpus.read_text())
    selected_runs = [
        run for run in corpus["runs"] if args.run is None or run["id"] == args.run
    ]
    output = {
        "schema_version": 1,
        "corpus": str(args.corpus),
        "protocol": {
            **corpus.get("protocol", {}),
            "reference_timing": "spoken-prompt-end",
        },
        "precision": args.precision,
        "first_speaker": args.first_speaker,
        "audible_output_evaluator": (
            None
            if args.skip_whisper
            else {
                "package": WHISPER_PACKAGE,
                "model": args.whisper_model,
                "model_revision": WHISPER_MODEL_REVISION,
            }
        ),
        "runs": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.audio_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="vibetalker-gate2-") as temporary:
        temporary_root = Path(temporary)
        sink = await start_transcript_sink()
        try:
            for run in selected_runs:
                log_root = (
                    args.log_dir / run["id"]
                    if args.log_dir is not None
                    else temporary_root
                )
                log_root.mkdir(parents=True, exist_ok=True)
                runtime = ManagedRuntime(
                    args.runtime_root,
                    log_root,
                    args.precision,
                    args.first_speaker,
                )
                await runtime.start()
                run_result = {"id": run["id"], "turns": []}
                try:
                    async with aiohttp.ClientSession() as session:
                        async with session.ws_connect(
                            "http://127.0.0.1:8999/api/chat",
                            timeout=aiohttp.ClientTimeout(
                                total=None,
                                sock_connect=5,
                            ),
                            max_msg_size=8 * 1_024 * 1_024,
                        ) as websocket:
                            handshake = await websocket.receive(timeout=5)
                            if (
                                handshake.type
                                != aiohttp.WSMsgType.BINARY
                                or handshake.data != b"\x00"
                            ):
                                raise RuntimeError(
                                    "Moshi returned an invalid WebSocket "
                                    "handshake"
                                )
                            opus_writer = sphn.OpusStreamWriter(SAMPLE_RATE)
                            opus_reader = sphn.OpusStreamReader(SAMPLE_RATE)
                            turns = run["turns"]
                            if args.limit is not None:
                                turns = turns[: args.limit]
                            for turn in turns:
                                injected_reference = turn["reference"]
                                if corpus.get("protocol", {}).get(
                                    "append_required_answer",
                                    False,
                                ):
                                    required_answer = " ".join(
                                        turn["required_phrases"]
                                    )
                                    injected_reference += (
                                        " The exact required answer is "
                                        f"{required_answer}. Say "
                                        f"{required_answer} clearly."
                                    )
                                injected_turn = {
                                    **turn,
                                    "reference": (
                                        ""
                                        if args.skip_reference
                                        else injected_reference
                                    ),
                                }
                                spoken_prompt = (
                                    corpus.get("protocol", {}).get(
                                        "spoken_prefix",
                                        "",
                                    )
                                    + turn["prompt"]
                                )
                                prompt_audio = (
                                    temporary_root / f"{turn['id']}.aiff"
                                )
                                response_audio = (
                                    args.audio_dir
                                    / f"{turn['id']}-response.wav"
                                )
                                audio = synthesize(
                                    spoken_prompt,
                                    prompt_audio,
                                    args.voice,
                                    args.speech_rate,
                                )
                                result = await run_turn(
                                    session,
                                    websocket,
                                    opus_writer,
                                    opus_reader,
                                    injected_turn,
                                    audio,
                                    args.response_seconds,
                                    response_audio,
                                    (
                                        None
                                        if args.skip_whisper
                                        else args.whisper_model
                                    ),
                                )
                                result["source_reference"] = turn["reference"]
                                result["spoken_prompt"] = spoken_prompt
                                run_result["turns"].append(result)
                                print(
                                    f"{turn['id']}: {result['score']} "
                                    f"ASR={result['asr']!r} "
                                    "audible="
                                    f"{result['audible_transcript']!r} "
                                    "model_text="
                                    f"{result['model_text']!r}",
                                    flush=True,
                                )
                finally:
                    if not args.keep_runtime:
                        await runtime.stop()
                scores = [turn["score"] for turn in run_result["turns"]]
                run_result["fully_correct"] = scores.count("fully_correct")
                run_result["contradictions"] = scores.count("contradiction")
                output["runs"].append(run_result)
                args.output.write_text(json.dumps(output, indent=2) + "\n")
        finally:
            await sink.cleanup()

    all_turns = [turn for run in output["runs"] for turn in run["turns"]]
    fully_correct = sum(turn["score"] == "fully_correct" for turn in all_turns)
    contradictions = sum(turn["score"] == "contradiction" for turn in all_turns)
    output["fully_correct"] = fully_correct
    output["contradictions"] = contradictions
    output["gate_passed"] = (
        len(all_turns) == 20
        and fully_correct >= 17
        and contradictions == 0
        and all(run["fully_correct"] >= 8 for run in output["runs"])
    )
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps({
        "fully_correct": fully_correct,
        "contradictions": contradictions,
        "gate_passed": output["gate_passed"],
    }))
    return 0 if output["gate_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
