#!/usr/bin/env python3
"""Model-check RelaxedReadApplied.tla with TLC for every case in model.json.

Usage:
  ./run.py                    run every case (about 8 minutes with 8 workers)
  ./run.py --case default     run one case; repeat --case for more
  ./run.py --list             list the cases
  ./run.py --workers 4        TLC worker threads (default: half of the CPUs)
  ./run.py --jar PATH         use this tla2tools.jar (or set TLA2TOOLS_JAR)

Without --jar or TLA2TOOLS_JAR, TLC v1.7.4 is downloaded once into
~/.cache/tla2tools/ and its SHA-256 is checked. Requires Python 3.8+ and Java 11+.

A normal case passes when TLC explores every state without a violation. A case with
"violation" or "witness" passes when TLC finds exactly that invariant violated: a
control that removes a protection, or a probe showing an interleaving is reachable.
Each case runs in a new temporary directory, printed at the end.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TLC_URL = "https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar"
TLC_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TLC_CACHE = Path.home() / ".cache" / "tla2tools" / "v1.7.4" / "tla2tools.jar"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tlc_jar(explicit):
    if explicit:
        return Path(explicit)
    if not TLC_CACHE.exists():
        TLC_CACHE.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {TLC_URL}", file=sys.stderr)
        partial = TLC_CACHE.with_suffix(".partial")
        with urllib.request.urlopen(TLC_URL) as resp, partial.open("wb") as out:
            shutil.copyfileobj(resp, out)
        partial.replace(TLC_CACHE)
    if sha256(TLC_CACHE) != TLC_SHA256:
        sys.exit(f"{TLC_CACHE} does not match SHA-256 {TLC_SHA256}; remove it and rerun")
    return TLC_CACHE


def cases(spec):
    """Return {name: (constants, invariants, expected violation or None)}."""
    defaults = spec["constants"]
    invariants = spec["invariants"]
    result = {"default": (defaults, invariants, None)}
    for name, case in spec.get("cases", {}).items():
        constants = {**defaults, **case.get("constants", {})}
        if "witness" in case:
            result[name] = (constants, invariants + [case["witness"]], case["witness"])
        else:
            result[name] = (constants, case.get("invariants", invariants), case.get("violation"))
    return result


def literal(value):
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value)


def config(constants, invariants):
    lines = ["CONSTANTS"]
    lines += [f"    {k} = {literal(v)}" for k, v in constants.items()]
    lines += ["INIT Init", "NEXT Next", "INVARIANTS"]
    lines += [f"    {inv}" for inv in invariants]
    return "\n".join(lines) + "\n"


def run_case(module, name, case, jar, workers, root):
    constants, invariants, expected = case
    directory = root / name
    directory.mkdir()
    shutil.copy(HERE / f"{module}.tla", directory)
    (directory / "model.cfg").write_text(config(constants, invariants))
    java = Path(os.environ["JAVA_HOME"]) / "bin" / "java" if "JAVA_HOME" in os.environ else "java"
    cmd = [str(java), "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC",
           "-workers", str(workers), "-deadlock", "-config", "model.cfg",
           "-metadir", str(directory / "states"), f"{module}.tla"]
    started = time.monotonic()
    proc = subprocess.run(cmd, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    elapsed = time.monotonic() - started
    (directory / "tlc.log").write_text(proc.stdout)
    shutil.rmtree(directory / "states", ignore_errors=True)

    found = re.search(r"Error: Invariant (\w+) is violated", proc.stdout)
    violated = found.group(1) if found else None
    if expected is None:
        ok = proc.returncode == 0 and violated is None and "No error has been found" in proc.stdout
        outcome = "no violation, all states explored" if ok else f"unexpected result: {violated or 'see tlc.log'}"
    else:
        ok = violated == expected
        outcome = f"found expected {expected} violation" if ok else f"expected {expected}, got {violated or 'none'}"
    states = re.findall(r"(\d[\d,]*) distinct states found", proc.stdout)
    detail = f"; {states[-1]} distinct states" if states else ""
    print(f"{'PASS' if ok else 'FAIL'} {name}: {outcome} ({elapsed:.0f}s{detail})", flush=True)
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--case", action="append", help="run only this case; repeatable")
    parser.add_argument("--list", action="store_true", help="list the cases and exit")
    parser.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument("--jar", default=os.environ.get("TLA2TOOLS_JAR"))
    args = parser.parse_args()

    spec = json.loads((HERE / "model.json").read_text())
    all_cases = cases(spec)
    if args.list:
        print("\n".join(all_cases))
        return 0
    selected = args.case or list(all_cases)
    unknown = [c for c in selected if c not in all_cases]
    if unknown:
        parser.error(f"unknown case: {', '.join(unknown)}")

    jar = tlc_jar(args.jar)
    root = Path(tempfile.mkdtemp(prefix="RelaxedReadApplied-"))
    passed = sum(run_case(spec["module"], c, all_cases[c], jar, args.workers, root) for c in selected)
    print(f"{passed}/{len(selected)} checks passed; logs in {root}")
    return 0 if passed == len(selected) else 1


if __name__ == "__main__":
    sys.exit(main())
