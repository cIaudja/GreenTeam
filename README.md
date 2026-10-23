# An Empirical Analysis of the Energy Consumption in Python JSON Libraries: `json` vs `orjson`

Replication package of the **Green Lab 2026/2027** team project (Vrije Universiteit Amsterdam, September–October 2026).
This repository is a fork of [Experiment Runner](https://github.com/S2-group/experiment-runner), the tool used to run the experiment;
its original README is in [`README-experiment-runner.md`](README-experiment-runner.md).

| | |
|---|---|
| **Report (PDF)** | [GreenTeam-Assignment3.pdf](https://www.overleaf.com/read/wyssgwwwzggh#fb5832) |
| **Video presentation** | [GreenTeam video](https://drive.google.com/file/d/11u0qBzEpmUCuT8SA4I2HXW3jhA4zuaED/view?usp=sharing)|
| **Time log** | [Google Sheet](https://docs.google.com/spreadsheets/d/15RhUCfX4DNIro8KFPGSOJ5Hlx_-_CwwgE7x4Oh0ZAfo/edit?usp=sharing) |

## 1. What is this experiment about?

Python's standard-library `json` module (C-accelerated) is the default choice for JSON handling, while `orjson`
(written in Rust) is advertised as a much faster drop-in alternative. Speed is not the same as energy efficiency,
so we measured both libraries in a controlled experiment on the Green Lab server `gl3`.

**Goal (GQM).** Analyse the `json` and `orjson` libraries for the purpose of comparative evaluation, with respect to
their energy consumption and performance, from the point of view of software developers, in the context of JSON
serialisation (`dumps`) and deserialisation (`loads`) in Python applications.

| ID | Research question |
|---|---|
| **RQ1** | What is the difference in energy consumption between `json` and `orjson` when performing JSON serialisation and deserialisation? |
| **RQ1.1** | How does payload complexity impact energy efficiency (J/KB) during serialisation and deserialisation in `json` and `orjson`? |
| **RQ2** | What is the relationship between energy consumption and performance in `json` and `orjson`? |
| **RQ2.1** | What is the relationship between energy consumption and RAM usage (peak RSS)? |
| **RQ2.2** | What is the relationship between energy consumption and CPU utilisation? |
| **RQ2.3** | What is the relationship between energy consumption and execution time? |

### Experiment design in a nutshell

* **Treatments:** library (`json` = control, `orjson`) × operation (`dumps`, `loads`).
* **Two blocks, analysed separately** (30 repetitions per configuration, randomised run order):

| Block | RQs | Payloads | Configurations | Runs |
|---|---|---|---|---|
| Synthetic | RQ1, RQ1.1 | `simple` (10 KB, depth 2, strings), `moderate` (1 MB, depth 10, mixed), `complex` (10 MB, depth 15, mixed) | 2 × 2 × 3 = 12 | 360 |
| Real-world | RQ2, RQ2.1–2.3 | `github` (R1), `twitter` (R2), `citm_catalog` (R3), `canada` (R4) | 2 × 2 × 4 = 16 | 480 |

* **Synthetic block:** every run processes the same volume of data, *V* = 30 GB, so energy efficiency is
  *EE = E / V* (J/KB). **Real-world block:** a fixed number of iterations per payload, identical for both libraries
  (`github` 500,000; `twitter` 45,000; `citm_catalog` 18,000; `canada` 3,500).
* **Measures:** energy *E* (J), execution time *T* (s), CPU utilisation (%), peak RSS (bytes, real-world block), idle
  power *P*<sub>idle</sub> (W, sampled in the last 10 s of each 60 s cool-down, not subtracted from *E*).
* **Statistics:** Shapiro–Wilk + Q–Q plots, Levene; ART ANOVA (library × complexity) with Mann–Whitney *U*,
  Cliff's δ and partial η² for RQ1/RQ1.1; Pearson/Spearman correlations with Fisher's *z* / bootstrap CI for RQ2;
  Benjamini–Hochberg correction within each block; α = 0.05.

## 2. Main findings (details in the report)

* **RQ1 / RQ1.1 (synthetic):** `orjson` used significantly less energy than `json` in every configuration.
  Median reduction: 87.4–92.9 % for `dumps` and 29.1–66.3 % for `loads`. The advantage shrinks as payload
  complexity grows (library × payload interaction significant for both operations).
* **RQ2 (real-world):** `orjson` used 89.6–94.9 % less energy for `dumps` and 54.2–68.9 % less for `loads`.
  Both libraries draw almost the same power (≈ 49 W median), so the saving comes almost entirely from finishing the
  same work sooner: energy is closely related to execution time, but not to peak RSS or CPU utilisation.

## 3. Repository structure

Structure follows the course guidelines for replication packages (data, source code, figures, text).

```
GreenTeam/
├── README.md                    this file
├── README-experiment-runner.md  original README of Experiment Runner
├── CITATION.cff                 citation metadata
├── requirements.txt             pinned Python dependency (orjson==3.12.0)
├── main.R                       runs the whole data analysis (both blocks)
├── experiment-runner/           Experiment Runner source code (fork of S2-group/experiment-runner, commit 56620fa)
├── data/
│   ├── synthetic-payloads/      simple.json, moderate.json, complex.json (+ *_metadata.json), generator.py
│   └── real-world-payloads/     github.json, twitter.json, citm_catalog.json, canada.json
├── run-tables/                  pre-generated, randomised run order (seeded) for both blocks
│   ├── run_table_synthetic.csv  360 runs
│   └── run_table_realworld.csv  480 runs
├── experiment-scripts/          source code to run the experiment and build the dataset
│   ├── RunnerConfig.py          Experiment Runner configuration (orchestration, measurement, checks)
│   ├── benchmark.py             one benchmark run (warm-up + measurement window, json or orjson)
│   ├── combine_results.py       merges the run tables of the 3 batches into results/*_all.csv
│   └── recompute_todo_runs.py   recomputes runs whose RAPL counter overflowed from the raw logs
├── results/                     raw data produced by the experiment
│   ├── json_energy_synthetic_batch{1,2,3}of3/   run_table.csv + one folder per run
│   ├── json_energy_real_world_batch{1,2,3}of3/  run_table.csv + one folder per run
│   ├── synthetic_all.csv        combined run table of the synthetic block (360 rows)
│   └── real_world_all.csv       combined run table of the real-world block (480 rows)
└── data-analysis/               R scripts and their outputs
    ├── synthetic_analysis_v3.R  synthetic block (RQ1, RQ1.1)
    ├── analysis_realworld.R     real-world block (RQ2, RQ2.1–2.3, supporting comparisons)
    ├── processed/               cleaned data used by the analysis (CSV)
    ├── tables/                  result tables (CSV + LaTeX, used in the report)
    └── figures/                 final figures (PDF: box/violin/density/Q–Q/interaction/scatter plots)
```

The other top-level folders (`documentation/`, `examples/`, `test/`, `test-standalone/`) come from Experiment Runner
and are not needed to replicate this study.

Each run folder in `results/…/run_<id>_repetition_<k>/` contains the raw measurements of that run:
`energibridge.csv` (RAPL/CPU/memory samples every 200 ms), `idle.csv` (cool-down samples for *P*<sub>idle</sub>),
`benchmark.json` (window timestamps, execution time, processed volume, RSS), `energibridge_stdout.log` and
Experiment Runner's `metadata.json`.

### Data dictionary (`run_table.csv`, `*_all.csv`)

| Column | Meaning |
|---|---|
| `__run_id` | Run identifier: configuration number and repetition (`run_<config>_repetition_<k>`) |
| `__done` | `DONE` if the run was executed and its measures were stored, `TODO` otherwise |
| `library`, `operation`, `payload` | Factors: `json`/`orjson`, `dumps`/`loads`, payload name |
| `execution_time_s` | Wall-clock duration of the measurement window (s) |
| `cpu_utilisation_pct` | Mean utilisation of the pinned core (EnergiBridge samples inside the window) |
| `peak_memory_bytes` | Increase of system `USED_MEMORY` in the window (EnergiBridge); only sanity-checked, not analysed (RQ2.1 uses `peak_rss_bytes`) |
| `energy_J` | CPU package + DRAM energy of socket 0 over the window (RAPL, counter overflows compensated) |
| `idle_power_W` | Mean power over the last 10 s of the 60 s cool-down |
| `peak_rss_bytes` | Peak RSS of the benchmark process minus its baseline (real-world block only; RQ2.1) |
| `batch` | Booking slot (1–3) in which the run was executed (`*_all.csv` only) |

Energy efficiency (J/KB) is not stored: the analysis derives it as `energy_J` divided by the volume
processed in the run (`volume_bytes` in `benchmark.json`, ≈ 30 GB).

## 4. Requirements

**Testbed (as used in the study).** Green Lab server `gl3`: 2 × Intel Xeon Silver 4208 @ 2.10 GHz (8 cores each,
SMT disabled), 12 × 32 GiB DDR4-3200, Ubuntu 24.04.4 LTS (kernel 7.0.0-28-generic), default `schedutil` governor
and turbo boost. The benchmark process is pinned to core 0 of socket 0 with `taskset`. Exclusive access is obtained
through the Green Lab booking system; the server is reached via SSH through the jump host `glgate`, and the runs are
started inside `tmux`.

**Software on the testbed.**

| Tool | Version | Purpose |
|---|---|---|
| CPython | 3.13.12 | Runs the benchmark (the C accelerator of `json` must be active) |
| [`orjson`](https://github.com/ijl/orjson) | 3.12.0 (`requirements.txt`) | Library under study |
| [Experiment Runner](https://github.com/S2-group/experiment-runner) | commit `56620fa` (included, this repository is a fork) | Orchestration, randomisation, cool-downs, run table |
| [EnergiBridge](https://github.com/tdurieux/EnergiBridge) | 0.0.7 | Energy measurement (RAPL, every 200 ms) |

`RunnerConfig.py` aborts if the Python or `orjson` version differs from the pinned ones, if the server is not idle
(load average > 0.5), if the `json` C accelerator is missing, or if the two libraries produce non-equivalent output
for any payload.

**Analysis (any machine).** R ≥ 4.x with the packages `tidyverse`, `jsonlite`, `ARTool`, `xtable` and `scales`
(installed automatically by the scripts if missing). Python 3 is only needed to regenerate the synthetic payloads
or to run the helper scripts.

## 5. How to replicate

### 5.1 Re-run the experiment (needs a machine with RAPL access, ideally `gl3`)

```bash
# one-time setup on the testbed
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
pip install pandas psutil tabulate dill jsonpickle   # dependencies of Experiment Runner (included in experiment-runner/)
# install EnergiBridge 0.0.7 and make sure `energibridge` is on the PATH (needs access to the RAPL counters)

# from the root of this repository, inside tmux
# smoke test (4 runs, small volume, separate results folder, NOT valid data)
DRY_RUN=1 EXPERIMENT_BLOCK=synthetic python3 experiment-runner/ experiment-scripts/RunnerConfig.py

# full blocks, in three booking slots each (BATCH=1,2,3)
BATCH=1 EXPERIMENT_BLOCK=synthetic  python3 experiment-runner/ experiment-scripts/RunnerConfig.py
BATCH=1 EXPERIMENT_BLOCK=real-world python3 experiment-runner/ experiment-scripts/RunnerConfig.py
```

* The run order is fixed by the pre-generated tables in `run-tables/`; `BATCH=k` executes the k-th contiguous slice
  (360 and 480 runs split into 3 batches, each in its own booked session). Results go to
  `results/json_energy_<block>_batch<k>of3/`. If a slot ends early, run the same command again: runs still marked
  `TODO` are resumed.
* Each run: 60 s cool-down (last 10 s sampled for *P*<sub>idle</sub>) → fresh core-pinned Python process → warm-up
  (1 % of the work, not measured) → measurement window → write measures. Before a block the testbed is warmed up with
  a CPU-bound load until the package temperature changes by ≤ 1 °C per minute.
* Runtime: ≈ 8.5 h per synthetic batch and ≈ 9 h per real-world batch (≈ 25.5 h and ≈ 26 h per block).
* **RAPL overflow.** The 32-bit RAPL counters wrap at 2<sup>18</sup> J. `RunnerConfig.py` compensates for this; runs
  that were marked `TODO` because of an overflow in an earlier version of the script can be recomputed from their
  complete raw logs, without re-executing them, with
  `python3 experiment-scripts/recompute_todo_runs.py <results folder>`.
* After all batches have finished, merge the run tables:

```bash
python3 experiment-scripts/combine_results.py --block synthetic     # -> results/synthetic_all.csv
python3 experiment-scripts/combine_results.py --block real-world    # -> results/real_world_all.csv
```

### 5.2 Re-run only the data analysis (no special hardware)

From the root of the repository:

```bash
Rscript main.R   # runs data-analysis/synthetic_analysis_v3.R (RQ1, RQ1.1) and data-analysis/analysis_realworld.R (RQ2.x)
```

The scripts read the raw data in `results/`, write the cleaned data to `data-analysis/processed/`, the tables
(CSV + LaTeX) to `data-analysis/tables/` and the figures (PDF) to `data-analysis/figures/`. Runs that are not
`DONE` are excluded. Outliers (1.5 × IQR) are flagged and kept; a sensitivity analysis without them is reported in
the paper. The bootstrap in the real-world script is seeded (`SEED = 2026`).

### 5.3 Regenerate the synthetic payloads

```bash
python3 data/synthetic-payloads/generator.py   # seed 42; writes simple/moderate/complex.json and *_metadata.json
```

The generator tunes the number of elements until the compact serialised size is within ±5 % of the target
(10 KB / 1 MB / 10 MB); the `*_metadata.json` files record the achieved size, depth and type counts.

## 6. Real-world payloads

The four real-world payloads are public JSON documents that are also used as fixtures in
[`orjson`'s benchmark suite](https://github.com/ijl/orjson): `github.json` (≈ 56 KB, REST API response),
`twitter.json` (≈ 632 KB, Unicode-heavy nested feed), `citm_catalog.json` (≈ 1.7 MB, repetitive integers/objects) and
`canada.json` (≈ 2.3 MB, floating-point coordinates). They were not created by us and keep their original licences.

## 7. Notes and deviations from the plan

* The experiment is split into 3 batches per block because a `gl3` booking cannot exceed 15 hours; the batches are
  contiguous slices of the same randomised order and are merged by `combine_results.py`.
* The analysis of the synthetic block uses the runs marked `DONE`; runs whose RAPL counter overflowed are
  recomputed from the raw logs (see 5.1) rather than re-executed.
* CPU utilisation and memory are taken from the EnergiBridge samples / `getrusage` instead of polling `psutil` in the
  benchmark process, to avoid adding work to the measured process.
* `idle_power_W` is recorded for every run to check that the testbed is in the same state before each run; it is not
  subtracted from the energy values.

## 8. Authors

| Name | Contact |
|---|---|
| Sophia Ballard | s.n.h.ballard@student.vu.nl |
| Claudia Cretti | c.cretti@student.vu.nl |
| Gonçalo Oliveira | g.francosimoesdeoliveira@student.vu.nl |
| Radu-Mihai Aldea | r.aldea@student.vu.nl |
| Emily Canas | e.e.canas@student.vu.nl |

Course: Green Lab 2026/2027, Vrije Universiteit Amsterdam.

## 9. How to cite

```bibtex
@misc{An_Empirical_Analysis_2026,
  author      = {Ballard, Sophia and Cretti, Claudia and Oliveira, Gon{\c{c}}alo and Aldea, Radu-Mihai and Canas, Emily},
  title       = {An Empirical Analysis of the Energy Consumption in Python JSON Libraries: json vs orjson},
  institution = {Vrije Universiteit Amsterdam},
  year        = {2026},
  note        = {Green Lab 2026/2027, Vrije Universiteit Amsterdam, September--October 2026},
  url         = {https://github.com/cIaudja/GreenTeam}
}
```
