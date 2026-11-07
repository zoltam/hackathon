#!/usr/bin/env python3
"""Read-only Create ML detector status. Use a fresh log per run; --watch follows it."""

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
TEST = re.compile(r"Held-out rendered test · (\d+) frames · TP (\d+) FP (\d+) FN (\d+) · IoU ≥ 0.50")


def trainers(executable):
    processes = subprocess.check_output(
        ["ps", "-axo", "pid=,state=,etime=,%cpu=,command="], text=True
    )
    prefix = str(executable)
    for line in processes.splitlines():
        pid, state, elapsed, cpu, command = line.split(maxsplit=4)
        if not state.startswith("Z") and (command == prefix or command.startswith(prefix + " ")):
            yield f"PID {pid} · elapsed {elapsed} · CPU {cpu}% · {command}"


def status(log, model, active, expected_sha256=None):
    log_text = log.read_text(errors="replace") if log.is_file() else ""
    lines = log_text.splitlines()
    export_marker = f"Exported {model.name}"
    export = max((index for index, line in enumerate(lines) if line == export_marker), default=-1)
    result = next((match for line in reversed(lines[export + 1:]) if (match := TEST.fullmatch(line))), None)
    exported = export >= 0
    present = model.is_file() and model.stat().st_size > 0
    phase = next((line.removeprefix("VALMET_TRAIN phase=") for line in reversed(lines)
                  if line.startswith("VALMET_TRAIN phase=")), None)
    checkpoint = next((line.removeprefix("VALMET_TRAIN checkpoint=") for line in reversed(lines)
                       if line.startswith("VALMET_TRAIN checkpoint=")), None)
    if active:
        state = "held-out test" if exported else phase or "training"
    elif result:
        state = "test finished"
    else:
        state = "inactive; no completed test in log"
    yield f"State: {state}"
    yield from active

    for split in ("train", "validation"):
        parsed = re.search(rf"/{split}/annotations\.json\nSuccessfully parsed (\d+) elements", log_text)
        if parsed:
            yield f"Create ML {split}: {parsed[1]} annotated frames loaded"
    progress = next((line.strip() for line in reversed(lines)
                     if re.match(r"\s*Iteration[: ]+\d", line, re.I)), None)
    if checkpoint:
        yield f"Latest checkpoint: {checkpoint}"
    elif active and not exported:
        yield f"Progress: {progress or 'iteration not reported in log yet'}"

    yield f"Export: {'logged' if exported else 'not logged'} · model: {'present' if present else 'missing'}"
    digest = hashlib.sha256(model.read_bytes()).hexdigest() if present and not active else None
    if digest:
        yield f"Model SHA-256: {digest}"
    if result:
        frames, tp, fp, fn = map(int, result.groups())
        yield f"Held-out rendered test: {frames} frames · TP {tp} · FP {fp} · FN {fn} · IoU ≥ 0.50"
    if active:
        gate = "pending"
    elif result and exported and present and model.stat().st_mtime <= log.stat().st_mtime:
        gate = "passed" if frames > 0 and tp > 0 else "failed: zero true positives"
    else:
        gate = "unverified: needs logged export, model and completed test from this run"
    if expected_sha256 and digest and expected_sha256.lower() != digest:
        gate = "failed: model hash differs from the evaluated export"
    yield f"Artifact smoke gate: {gate}"
    if lines and not result:
        yield f"Last log: {lines[-1]}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true", help="refresh on changes; Ctrl-C exits monitor only")
    parser.add_argument("--log", type=Path, default=Path("/tmp/valmet-detector-training.log"))
    parser.add_argument("--model", type=Path, default=ROOT / "assets/valmet/equipment-detector.mlmodel")
    parser.add_argument("--trainer", type=Path, default=Path("/tmp/valmet-train-equipment"))
    parser.add_argument("--expected-sha256", help="Bind the smoke gate to the evaluated model")
    args = parser.parse_args()
    previous = None
    try:
        while True:
            current = "\n".join(status(args.log, args.model, list(trainers(args.trainer)), args.expected_sha256))
            if current != previous:
                print(current, "", sep="\n", flush=True)
                previous = current
            if not args.watch:
                break
            time.sleep(5)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
