#!/usr/bin/env python3
"""Temporary bounded CI reproduction; sample only descendants of this test run."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


output = Path(os.environ.get("AE_DIAGNOSTIC_OUTPUT", "ci-hang-evidence"))
output.mkdir(exist_ok=True)
idle_timeout = int(os.environ.get("AE_DIAGNOSTIC_IDLE_TIMEOUT", "120"))
timeout = int(os.environ.get("AE_DIAGNOSTIC_TIMEOUT", "360"))


def descendants(root):
    listing = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,command="], text=True
    )
    rows = [line.strip().split(None, 2) for line in listing.splitlines()]
    owned = {root}
    while True:
        children = {int(row[0]) for row in rows if int(row[1]) in owned}
        expanded = owned | children
        if expanded == owned:
            return [(int(row[0]), row[2]) for row in rows if int(row[0]) in owned]
        owned = expanded


def snapshot(process, label):
    children = descendants(process.pid)
    (output / f"{label}-processes.txt").write_text(
        "\n".join(f"{pid} {command}" for pid, command in children) + "\n"
    )
    for pid, command in children:
        if ".xctest" in command or "swiftpm-testing" in command:
            subprocess.run(
                ["sample", str(pid), "5", "-file", str(output / f"{label}-{pid}.sample.txt")],
                timeout=20,
                check=False,
            )


process = None
try:
    with (output / "swift-test.log").open("wb") as log:
        process = subprocess.Popen(
            sys.argv[1:] or ["swift", "test", "--skip-build"],
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        print(f"Owned swift test PID: {process.pid}", flush=True)
        started = time.monotonic()
        changed = started
        previous_size = 0
        sampled = False
        while process.poll() is None:
            size = os.fstat(log.fileno()).st_size
            now = time.monotonic()
            if size != previous_size:
                previous_size = size
                changed = now
            if not sampled and now - changed > 30:
                snapshot(process, "stalled")
                sampled = True
            if now - changed > idle_timeout or now - started > timeout:
                snapshot(process, "deadline")
                raise TimeoutError(f"command exceeded {idle_timeout}s without output or {timeout}s total")
            time.sleep(1)
        raise SystemExit(process.returncode)
finally:
    if process is not None and process.poll() is None:
        children = descendants(process.pid)
        for pid, _ in reversed(children):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            for pid, _ in reversed(children):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=10)
    print((output / "swift-test.log").read_text(errors="replace"), flush=True)
