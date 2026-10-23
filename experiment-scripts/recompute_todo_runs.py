#!/usr/bin/env python3
"""
Fill in the run-table rows that Experiment Runner left as TODO because the RAPL
energy counter overflowed (wrapped around 2^18 J) during the measurement window.

The raw EnergiBridge logs of these runs are complete; only the post-processing
failed ("negative energy"). This script recomputes the measures from the raw logs
with exactly the same procedure as RunnerConfig.populate_run_data, plus the
counter unwrapping now also included in RunnerConfig.window_energy.

Usage (from the repository root):
    python3 experiment-scripts/recompute_todo_runs.py results/json_energy_synthetic
"""
import csv
import json
import math
import sys
from bisect import bisect_right
from pathlib import Path

# Same constants as RunnerConfig.py
TIME_COL, PKG_COL, DRAM_COL = "Time", "PACKAGE_ENERGY (J)", "DRAM_ENERGY (J)"
CPU_COL, MEM_COL = "CPU_USAGE_0", "USED_MEMORY"
RAPL_WRAP_J = 262144.0


def read_samples(path):
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        cols = {k.strip(): [] for k in reader.fieldnames}
        for row in reader:
            for k, v in row.items():
                if k is not None:
                    try:
                        cols[k.strip()].append(float(v))
                    except (TypeError, ValueError):
                        cols[k.strip()].append(float("nan"))
    return cols


def unwrap_counter(vals):
    out, offset, prev = [], 0.0, None
    for v in vals:
        if prev is not None and not math.isnan(v) and not math.isnan(prev) and v < prev:
            offset += RAPL_WRAP_J
        out.append(v + offset)
        if not math.isnan(v):
            prev = v
    return out


def interp(ts, vals, t):
    if t < ts[0] or t > ts[-1]:
        raise ValueError(f"timestamp {t} outside EnergiBridge samples")
    i = min(max(bisect_right(ts, t), 1), len(ts) - 1)
    ta, tb, va, vb = ts[i - 1], ts[i], vals[i - 1], vals[i]
    return va if tb == ta else va + (vb - va) * (t - ta) / (tb - ta)


def window_energy(cols, t0, t1):
    ts = cols[TIME_COL]
    pkg = unwrap_counter(cols[PKG_COL])
    e = interp(ts, pkg, t1) - interp(ts, pkg, t0)
    dram = cols.get(DRAM_COL)
    if dram and not any(math.isnan(v) for v in dram) and max(dram) > 0:
        dram = unwrap_counter(dram)
        e += interp(ts, dram, t1) - interp(ts, dram, t0)
    if e < 0:
        raise ValueError("negative energy even after unwrapping")
    return e


def window_cpu_and_memory(cols, t0, t1):
    ts = cols[TIME_COL]
    inside = [i for i, t in enumerate(ts) if t0 <= t <= t1]
    cpu = [cols[CPU_COL][i] for i in inside if not math.isnan(cols[CPU_COL][i])]
    mem = [cols[MEM_COL][i] for i in inside]
    before = [i for i, t in enumerate(ts) if t <= t0]
    baseline = cols[MEM_COL][before[-1]] if before else mem[0]
    return sum(cpu) / len(cpu), max(mem) - baseline


def main(results_dir: Path) -> int:
    table_path = results_dir / "run_table.csv"
    with open(table_path, newline="") as f:
        reader = csv.DictReader(f)
        fields, rows = reader.fieldnames, list(reader)

    fixed = 0
    for row in rows:
        if row["__done"].strip() == "DONE":
            continue
        run_dir = results_dir / row["__run_id"]
        bench = json.loads((run_dir / "benchmark.json").read_text())
        cols = read_samples(run_dir / "energibridge.csv")
        t0, t1 = bench["start_time_ms"], bench["end_time_ms"]
        cpu, mem = window_cpu_and_memory(cols, t0, t1)
        idle = read_samples(run_dir / "idle.csv")
        its = idle[TIME_COL]
        p_idle = window_energy(idle, its[0], its[-1]) / ((its[-1] - its[0]) / 1000.0)
        row.update({"execution_time_s": bench["execution_time_s"], "cpu_utilisation_pct": cpu,
                    "peak_memory_bytes": mem, "energy_J": window_energy(cols, t0, t1),
                    "idle_power_W": p_idle, "__done": "DONE"})
        fixed += 1
        print(f"{row['__run_id']}: {row['library']} {row['operation']} {row['payload']} "
              f"-> {row['energy_J']:.1f} J")

    with open(table_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"{fixed} runs recomputed and marked DONE in {table_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1] if len(sys.argv) > 1 else "results/json_energy_synthetic")))
