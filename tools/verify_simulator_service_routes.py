"""Run the six RF-DETR service journeys on an installed iOS simulator build."""

import argparse
import json
from pathlib import Path
import subprocess
import time


ROUTES = (
    ("P-001", "far-circulation-pump", 69, 65),
    ("P-002", "black-circulation-pump", 69, 65),
    ("P-003", "wall-circulation-pump", 66, 92),
    ("P-004", "middle-circulation-pump", 67, 65),
    ("P-005", "red-circulation-pump", 69, 65),
    ("CV-003", "blue-inline-valve", 69, 65),
)
SIMCTL = ["xcrun", "simctl"]


def verify_route(simulator, bundle, output, route):
    tag, target, x, z = route
    target_id = f"boiler-room:{target}"
    payload = subprocess.check_output(
        ["dart", "tools/verify_service_route.dart", target_id, str(x), str(z)],
        text=True,
    )
    planned = json.loads(payload)
    if planned["targetID"] != target_id or planned["route"][:1] != [[x, z]]:
        raise ValueError(f"Unexpected target or start for {tag}")
    path = output / f"{tag}.log"
    with path.open("w", encoding="utf-8") as log:
        log.write(f"Test target={target_id} start=[{x},{z}]\n")
        log.flush()
        app = subprocess.Popen(
            [*SIMCTL, "launch", "--console", "--terminate-running-process", simulator, bundle,
             "--verify-service-journey", payload, "--simulator-rf16-journey"],
            stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 90
            while True:
                lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
                if (any(line.startswith("VALMET_JOURNEY result=") for line in lines)
                        or app.poll() is not None or time.monotonic() >= deadline):
                    break
                time.sleep(0.25)
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait()

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    passed = route_passed(lines, tag, target_id)
    print(f"{tag} {'PASS' if passed else 'FAIL'} ({path})", flush=True)
    return passed


def route_passed(lines, tag, target_id):
    expected = (
        "VALMET_JOURNEY checks arrived=true vision_confirmed=true "
        f"arrival_workbook=true workbook_tag={tag} mapped_nearby=true"
    )
    results = [line for line in lines if line.startswith("VALMET_JOURNEY result=")]
    return (
        "VALMET_JOURNEY vision_source=simulator-rf16" in lines
        and f"VALMET_JOURNEY phase=target_confirmed id={target_id}" in lines
        and expected in lines
        and len(results) == 1 and results[0].startswith("VALMET_JOURNEY result=passed ")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="UDID of a booted simulator")
    parser.add_argument("output", type=Path, help="New folder for journey logs")
    parser.add_argument("--bundle", default="com.example.valmetFieldApp")
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output([*SIMCTL, "list", "devices", "booted", "-j"]))
    if not any(device["udid"] == args.simulator and device["state"] == "Booted"
               for runtime, group in devices["devices"].items() if ".iOS-" in runtime
               for device in group):
        parser.error("simulator must be the UDID of a booted iOS simulator")
    subprocess.run([*SIMCTL, "get_app_container", args.simulator, args.bundle, "app"],
                   check=True, stdout=subprocess.DEVNULL)
    args.output.mkdir(parents=True)
    try:
        results = [verify_route(args.simulator, args.bundle, args.output, route) for route in ROUTES]
    finally:
        subprocess.run([*SIMCTL, "launch", "--terminate-running-process", args.simulator, args.bundle],
                       check=False, timeout=20)
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
