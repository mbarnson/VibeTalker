#!/usr/bin/env python3

import argparse
import json
import os
import signal
import statistics
import time
import urllib.request
import uuid
from pathlib import Path


INSTRUCTIONS = """\
You are VibeTalker's conversational Interactor. Echo the utterance UUID from \
the newest input exactly; never reuse an earlier UUID. Return one factual \
Reference of at most 180 characters for the voice model.

Apply these rules in order:
1. A transcript mentioning pi, a coding job, coding task, current task, agent, \
or sandbox work and asking about doing, status, state, running, finished, \
completed, active, or progress MUST set operation to "status" with a null instruction. Do \
not answer or guess the job state yourself; the Coordinator will supply \
grounded evidence. A direct request to stop, cancel, or abort that job MUST \
set operation to "cancel" with a null instruction.
2. Questions not matched by rule 1 and beginning Who, What, When, Where, Why, \
How, Is, Does, \
Explain, Tell, Define, Give, or Summarize MUST set pi_request to null, even \
when they mention code, tests, files, or action verbs.
3. A direct imperative whose first word is Add, Create, Fix, Implement, \
Improve, Refactor, Rename, Update, Run, Test, Write, or Document MUST set \
operation to "start". Also use "start" for another unambiguous direct request \
to change code, documentation, tests, or files. Copy the complete request \
verbatim into pi_request.instruction.
4. Quoted, conditional, or hypothetical requests set pi_request to null.
Otherwise set pi_request to null. Never claim that work started, finished, or \
changed a file; only the Coordinator has that evidence.

Examples:
- "What does actor isolation protect?" -> pi_request: null
- "Add a test for empty input." -> pi_request: \
{"operation":"start","instruction":"Add a test for empty input."}
- "What is pi doing right now?" -> pi_request: \
{"operation":"status","instruction":null}
"""

OUTPUT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["utterance_id", "reference_response", "pi_request"],
    "properties": {
        "utterance_id": {"type": "string", "format": "uuid"},
        "reference_response": {
            "type": "string",
            "minLength": 1,
            "maxLength": 220,
        },
        "pi_request": {
            "anyOf": [
                {"type": "null"},
                {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["operation", "instruction"],
                    "properties": {
                        "operation": {
                            "type": "string",
                            "enum": ["start", "cancel", "status"],
                        },
                        "instruction": {
                            "anyOf": [
                                {"type": "string", "maxLength": 4_000},
                                {"type": "null"},
                            ]
                        },
                    },
                },
            ]
        },
    },
}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * fraction) - 1))
    return ordered[index]


def completed_response(lines) -> tuple[str | None, str]:
    for raw_line in lines:
        line = raw_line.decode("utf-8").strip()
        if not line.startswith("data:"):
            continue
        payload = line.removeprefix("data:").strip()
        if not payload or payload == "[DONE]":
            continue
        event = json.loads(payload)
        if event.get("type") in ("response.failed", "error"):
            raise RuntimeError(json.dumps(event))
        if event.get("type") != "response.completed":
            continue
        response = event["response"]
        text = response.get("output_text")
        if not text:
            text = next(
                content["text"]
                for output in response.get("output", [])
                for content in output.get("content", [])
                if content.get("type") == "output_text"
            )
        return response.get("id"), text
    raise RuntimeError("stream ended before response.completed")


def reconciled_request(transcript: str, model_request):
    normalized = transcript.strip()
    lowercased = normalized.lower()
    words = "".join(
        character if character.isalpha() else " "
        for character in lowercased
    ).split()
    first_word = words[0] if words else None
    hypothetical = any(
        marker in lowercased
        for marker in (
            "hypothetically",
            "if i asked",
            "if someone asked",
            "suppose ",
            "imagine ",
            "quoted request",
            "quote:",
        )
    )
    subjects = (
        " pi ",
        "pi ",
        "coding job",
        "coding task",
        "current task",
        "sandbox",
        "sandbox task",
        "sandbox work",
        "job controller",
        "agent",
        "any work",
        "coding progress",
        "coding request",
        "cancellation",
        "requested edit",
        " job",
    )
    states = (
        "doing",
        "status",
        "state",
        "running",
        "finished",
        "completed",
        "complete",
        "active",
        "progress",
        "pending",
        "fail",
        "started",
        "happening",
        "processing",
        "up to",
        "report",
        "idle",
        "working",
        "verified",
    )
    padded = f" {lowercased} "
    grounded_status = any(subject in padded for subject in subjects) and any(
        state in lowercased for state in states
    )
    if hypothetical:
        return None
    if (
        first_word in ("stop", "cancel", "abort")
        or lowercased.startswith("please stop ")
        or lowercased.startswith("please cancel ")
    ):
        return {"operation": "cancel", "instruction": None}
    if first_word in (
        "add",
        "create",
        "fix",
        "implement",
        "improve",
        "refactor",
        "rename",
        "update",
        "run",
        "test",
        "write",
        "document",
    ):
        return {"operation": "start", "instruction": normalized}
    if grounded_status:
        return {"operation": "status", "instruction": None}
    if first_word in (
        "who",
        "what",
        "when",
        "where",
        "why",
        "how",
        "is",
        "does",
        "explain",
        "tell",
        "define",
        "give",
        "summarize",
    ):
        return None
    return model_request


def run_turn(
    endpoint: str,
    model: str,
    api_key: str,
    category: str,
    transcript: str,
    previous_response_id: str | None,
    reasoning_effort: str | None,
    timeout: float,
) -> dict:
    utterance_id = str(uuid.uuid4())
    body = {
        "model": model,
        "store": False,
        "stream": True,
        "instructions": INSTRUCTIONS,
        "input": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            f"utterance_id: {utterance_id}\n"
                            f"transcript: {transcript}"
                        ),
                    }
                ],
            }
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "vibetalker_interaction",
                "strict": True,
                "schema": OUTPUT_SCHEMA,
            }
        },
    }
    if previous_response_id:
        body["previous_response_id"] = previous_response_id
    if reasoning_effort:
        body["reasoning"] = {"effort": reasoning_effort}
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Accept": "text/event-stream",
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    def deadline_reached(_signal, _frame):
        raise TimeoutError(f"Interaction exceeded {timeout:.1f} seconds")

    started = time.perf_counter()
    previous_handler = signal.signal(signal.SIGALRM, deadline_reached)
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_id, structured_text = completed_response(response)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
    latency = time.perf_counter() - started
    output = json.loads(structured_text)
    expected_operation = {
        "ordinary": None,
        "dispatch": "start",
        "status": "status",
    }[category]
    model_request = output.get("pi_request")
    request_output = reconciled_request(transcript, model_request)
    actual_operation = request_output and request_output.get("operation")
    instruction_valid = (
        request_output.get("instruction") == transcript
        if expected_operation == "start" and request_output
        else request_output is None
        or request_output.get("instruction") is None
    )
    valid = (
        0 < len(output.get("reference_response", "")) <= 220
        and actual_operation == expected_operation
        and instruction_valid
    )
    return {
        "utterance_id": utterance_id,
        "category": category,
        "transcript": transcript,
        "latency_seconds": round(latency, 6),
        "valid": valid,
        "expected_operation": expected_operation,
        "actual_operation": actual_operation,
        "model_operation": model_request and model_request.get("operation"),
        "model_utterance_id_matches": (
            output.get("utterance_id", "").lower() == utterance_id
        ),
        "instruction_valid": instruction_valid,
        "response_id": response_id,
        "output": output,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corpus",
        type=Path,
        default=Path("Fixtures/Gate4/latency-corpus.json"),
    )
    parser.add_argument(
        "--endpoint",
        default="http://127.0.0.1:8000/v1/responses",
    )
    parser.add_argument("--model", required=True)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--sample-per-category", type=int)
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--maximum-chained-turns", type=int, default=1)
    parser.add_argument("--reasoning-effort")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    api_key = os.environ.get("OMLX_API_KEY")
    if not api_key:
        raise SystemExit("OMLX_API_KEY is required")
    corpus = json.loads(args.corpus.read_text())
    cases = [
        (category, transcript)
        for category in ("ordinary", "dispatch", "status")
        for transcript in corpus[category]
    ]
    if len(cases) != 100:
        raise SystemExit(f"expected 100 frozen turns, found {len(cases)}")
    if args.limit is not None:
        cases = cases[: args.limit]
    if args.sample_per_category is not None:
        cases = [
            (category, transcript)
            for category in ("ordinary", "dispatch", "status")
            for transcript in corpus[category][: args.sample_per_category]
        ]

    previous_response_id = None
    for _ in range(args.warmup):
        run_turn(
            args.endpoint,
            args.model,
            api_key,
            "ordinary",
            "Briefly define deterministic behavior.",
            None,
            args.reasoning_effort,
            args.timeout,
        )

    previous_response_id = None
    results = []
    chained_turn_count = 0
    for index, (category, transcript) in enumerate(cases, start=1):
        if chained_turn_count >= args.maximum_chained_turns:
            previous_response_id = None
            chained_turn_count = 0
        turn_started = time.perf_counter()
        try:
            result = run_turn(
                args.endpoint,
                args.model,
                api_key,
                category,
                transcript,
                previous_response_id,
                args.reasoning_effort,
                args.timeout,
            )
            previous_response_id = result["response_id"]
            chained_turn_count = chained_turn_count + 1 if previous_response_id else 0
        except Exception as error:
            result = {
                "category": category,
                "transcript": transcript,
                "latency_seconds": round(time.perf_counter() - turn_started, 6),
                "valid": False,
                "expected_operation": {
                    "ordinary": None,
                    "dispatch": "start",
                    "status": "status",
                }[category],
                "actual_operation": None,
                "response_id": None,
                "error": f"{type(error).__name__}: {error}",
            }
            previous_response_id = None
            chained_turn_count = 0
        results.append(result)
        print(
            f"{index:03d}/{len(cases):03d} {category:<8} "
            f"{result['latency_seconds']:.3f}s "
            f"{'PASS' if result['valid'] else 'FAIL'}",
            flush=True,
        )

    latencies = [result["latency_seconds"] for result in results]
    summary = {
        "schema_version": 1,
        "model": args.model,
        "endpoint": args.endpoint,
        "maximum_chained_turns": args.maximum_chained_turns,
        "reasoning_effort": args.reasoning_effort,
        "turn_count": len(results),
        "valid_count": sum(result["valid"] for result in results),
        "median_seconds": round(statistics.median(latencies), 6),
        "p95_seconds": round(percentile(latencies, 0.95), 6),
        "over_three_seconds": sum(value > 3 for value in latencies),
        "categories": {
            category: {
                "count": sum(r["category"] == category for r in results),
                "valid": sum(
                    r["category"] == category and r["valid"] for r in results
                ),
                "median_seconds": round(
                    statistics.median(
                        r["latency_seconds"]
                        for r in results
                        if r["category"] == category
                    ),
                    6,
                ),
                "p95_seconds": round(
                    percentile(
                        [
                            r["latency_seconds"]
                            for r in results
                            if r["category"] == category
                        ],
                        0.95,
                    ),
                    6,
                ),
            }
            for category in ("ordinary", "dispatch", "status")
            if any(r["category"] == category for r in results)
        },
    }
    report = {"summary": summary, "results": results}
    print(json.dumps(summary, indent=2))
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
