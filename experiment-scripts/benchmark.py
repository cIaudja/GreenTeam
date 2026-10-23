#!/usr/bin/env python3
"""
Benchmark script for ONE run of the json-vs-orjson experiment.

It is launched by RunnerConfig.py as:
    energibridge -o <csv> --summary taskset -c <core> python benchmark.py ...

Protocol (plan sections 4.2 and 5.4):
  setup (not measured): load payload file, parse it for dumps runs,
                        run N = ceil(0.01 V / s) warm-up iterations
  measurement window  : synthetic block  -> repeat until V bytes were processed
                                            (iterations = ceil(V / s), --volume-bytes)
                        real-world block -> fixed number of iterations
                                            (--iterations), no volume V;
                                            warm-up = 1% of the iterations
                        start/end wall-clock timestamps are logged so the runner
                        can integrate the EnergiBridge samples over exactly this window
s (bytes per operation) = length of the serialised output for dumps,
                          length of the input document for loads.
"""
import argparse
import json
import resource
import sys
import time
from itertools import repeat
from pathlib import Path

import orjson

PRE_WINDOW_PAUSE_S = 0.4   # guarantees an EnergiBridge sample just before the window
POST_WINDOW_PAUSE_S = 0.5  # guarantees an EnergiBridge sample just after the window


def json_dumps(obj) -> bytes:
    # Same task as orjson.dumps(obj): compact UTF-8 bytes (plan, "Library configuration").
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


OPERATIONS = {
    ("json", "dumps"): json_dumps,
    ("orjson", "dumps"): orjson.dumps,
    ("json", "loads"): json.loads,      # both loads functions receive the same bytes
    ("orjson", "loads"): orjson.loads,
}


def maxrss_bytes() -> int:
    """Peak RSS (high-water mark) of THIS process; ru_maxrss is KiB on Linux, bytes on macOS."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024)


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def run_loop(fn, arg, n: int) -> None:
    for _ in repeat(None, n):
        fn(arg)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", choices=["json", "orjson"], required=True)
    ap.add_argument("--operation", choices=["dumps", "loads"], required=True)
    ap.add_argument("--payload-file", type=Path, required=True)
    ap.add_argument("--result-file", type=Path, required=True)
    work = ap.add_mutually_exclusive_group(required=True)
    work.add_argument("--volume-bytes", type=int)   # synthetic block: V = 10 GB (decimal)
    work.add_argument("--iterations", type=int)     # real-world block: fixed iteration count
    args = ap.parse_args()

    fn = OPERATIONS[(args.library, args.operation)]
    rss_start = maxrss_bytes()   # interpreter + imports, before the payload is loaded

    # ---- setup (not measured) -------------------------------------------
    raw = args.payload_file.read_bytes()
    if args.operation == "dumps":
        arg = json.loads(raw)           # same Python object for both libraries
        bytes_per_op = len(fn(arg))     # size of the serialised output
    else:
        arg = raw
        bytes_per_op = len(raw)         # size of the input document

    if args.volume_bytes is not None:
        iterations = ceil_div(args.volume_bytes, bytes_per_op)
        warmup_iterations = ceil_div(args.volume_bytes // 100,
                                     bytes_per_op)
    else:
        iterations = args.iterations
        warmup_iterations = max(1, ceil_div(iterations, 100))

    run_loop(fn, arg, warmup_iterations)
    time.sleep(PRE_WINDOW_PAUSE_S)

    # ---- measurement window ---------------------------------------------
    rss_before = maxrss_bytes()
    start_ns = time.time_ns()
    t0 = time.perf_counter()
    run_loop(fn, arg, iterations)
    t1 = time.perf_counter()
    end_ns = time.time_ns()
    rss_after = maxrss_bytes()
    # ----------------------------------------------------------------------

    args.result_file.write_text(json.dumps({
        "library": args.library,
        "operation": args.operation,
        "payload_file": str(args.payload_file),
        "volume_bytes": iterations * bytes_per_op,  # volume actually processed
        "bytes_per_op": bytes_per_op,
        "iterations": iterations,
        "warmup_iterations": warmup_iterations,
        "start_time_ms": start_ns / 1e6,   # epoch ms, same clock as EnergiBridge "Time"
        "end_time_ms": end_ns / 1e6,
        "execution_time_s": t1 - t0,
        "maxrss_start_bytes": rss_start,
        "maxrss_before_bytes": rss_before,
        "maxrss_after_bytes": rss_after,
    }, indent=2))

    time.sleep(POST_WINDOW_PAUSE_S)
    return 0


if __name__ == "__main__":
    sys.exit(main())