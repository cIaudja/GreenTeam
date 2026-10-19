#!/usr/bin/env python3
"""Concatenate the run tables of all batches of a block into results/<block>_all.csv
(adds a `batch` column). Run from the project root:

    python3 experiment-scripts/combine_results.py --block real-world
    python3 experiment-scripts/combine_results.py --block synthetic
"""
import argparse
import csv
import re
from glob import glob
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"

ap = argparse.ArgumentParser()
ap.add_argument("--block", choices=["real-world", "synthetic"], required=True)
name = ap.parse_args().block.replace("-", "_")

folders = sorted(glob(str(RESULTS / f"json_energy_{name}_batch*of*")),
                 key=lambda f: int(re.search(r"batch(\d+)of", f)[1]))
if not folders:
    raise SystemExit(f"No folders matching results/json_energy_{name}_batch*of*")

rows, header = [], None
for folder in folders:
    batch = int(re.search(r"batch(\d+)of", folder)[1])
    with open(Path(folder) / "run_table.csv", newline="") as f:
        reader = csv.DictReader(f)
        header = header or reader.fieldnames
        rows += [{**r, "batch": batch} for r in reader]

out = RESULTS / f"{name}_all.csv"
with open(out, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=header + ["batch"])
    writer.writeheader()
    writer.writerows(rows)
print(f"Wrote {out}: {len(rows)} rows from {len(folders)} batches")