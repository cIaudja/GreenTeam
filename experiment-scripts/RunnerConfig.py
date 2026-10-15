"""
Experiment Runner config for "json vs orjson" (Green Lab 2026/2027).

Run on gl3, inside tmux, from the project root:
    EXPERIMENT_BLOCK=synthetic  python3 <path-to>/experiment-runner/experiment-runner/ experiment-scripts/RunnerConfig.py
    EXPERIMENT_BLOCK=real-world python3 <path-to>/experiment-runner/experiment-runner/ experiment-scripts/RunnerConfig.py
Add DRY_RUN=1 for a ~2 minute smoke test (4 runs, small volume, separate results folder).

The pre-generated run table (run-tables/run_table_<block>.csv) fixes the order of the runs.
"""
import csv
import json
import math
import os
import platform
import subprocess
import sys
import time
from bisect import bisect_right
from collections import Counter, deque
from glob import glob
from pathlib import Path

from EventManager.Models.RunnerEvents import RunnerEvents
from EventManager.EventSubscriptionController import EventSubscriptionController
from ConfigValidator.Config.Models.RunTableModel import RunTableModel
from ConfigValidator.Config.Models.FactorModel import FactorModel
from ConfigValidator.Config.Models.RunnerContext import RunnerContext
from ConfigValidator.Config.Models.OperationType import OperationType

# ---------------------------------------------------------------- block -----
BLOCK = os.environ.get("EXPERIMENT_BLOCK")
if BLOCK not in ("synthetic", "real-world"):
    raise RuntimeError("Set EXPERIMENT_BLOCK=synthetic or EXPERIMENT_BLOCK=real-world")
DRY_RUN = os.environ.get("DRY_RUN") == "1"

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
BENCHMARK_SCRIPT = SCRIPT_DIR / "benchmark.py"
SYNTH, REAL = PROJECT_ROOT / "data/synthetic-payloads", PROJECT_ROOT / "data/real-world-payloads"

PAYLOADS = {
    "synthetic": {"simple": SYNTH / "simple.json", "moderate": SYNTH / "moderate.json",
                  "complex": SYNTH / "complex.json"},
    "real-world": {"github": REAL / "github.json", "twitter": REAL / "twitter.json",
                   "citm_catalog": REAL / "citm_catalog.json", "canada": REAL / "canada.json"},
}[BLOCK]
RUN_TABLE = PROJECT_ROOT / ("run-tables/run_table_synthetic.csv" if BLOCK == "synthetic"
                            else "run-tables/run_table_realworld.csv")
EXPECTED_RUNS = 360 if BLOCK == "synthetic" else 480

# ------------------------------------------------------------ protocol ------
REPETITIONS = 30
VOLUME_BYTES = 30_000_000_000          # V = 30 GB (synthetic block only)
# Real-world block: no volume V, fixed iterations per payload (same for both libraries).
# Calibrated with pilot.py so the fastest configuration (orjson dumps) runs ~12 s per payload.
REAL_WORLD_ITERATIONS = {"github": 500_000, "twitter": 45_000,
                         "citm_catalog": 18_000, "canada": 3_500}
COOLDOWN_S, IDLE_SAMPLE_S = 60, 10    # cool-down; its last 10 s are sampled for P_idle
if DRY_RUN:                            # NOT valid data
    VOLUME_BYTES = 1_000_000_000
    REAL_WORLD_ITERATIONS = {k: max(1, v // 30) for k, v in REAL_WORLD_ITERATIONS.items()}
    COOLDOWN_S, IDLE_SAMPLE_S = 12, 4

PIN_CORE = 0                           # core 0 of socket 0
EXPECTED_PYTHON, EXPECTED_ORJSON = "3.13.12", "3.12.0"
MAX_IDLE_LOADAVG = 0.5

# EnergiBridge CSV columns (verify against a real log)
TIME_COL = "Time"                      # epoch ms
PKG_COL = "PACKAGE_ENERGY (J)"         # cumulative joules
DRAM_COL = "DRAM_ENERGY (J)"           # cumulative joules, if exposed
CPU_COL = f"CPU_USAGE_{PIN_CORE}"
MEM_COL = "USED_MEMORY"                # bytes

DATA_COLUMNS = ["execution_time_s", "cpu_utilisation_pct", "peak_memory_bytes", "energy_J",
                "idle_power_W"]  # idle_power_W: supporting measure (mean power, last IDLE_SAMPLE_S of cool-down)
if BLOCK == "real-world":        # RQ2.1: peak RSS of the benchmark process (see benchmark.py)
    DATA_COLUMNS = DATA_COLUMNS + ["peak_rss_bytes"]


# ----------------------------------------------------- EnergiBridge logs -----
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


def _interp(ts, vals, t):
    """Linear interpolation of a cumulative counter at time t."""
    if t < ts[0] or t > ts[-1]:
        raise ValueError(f"timestamp {t} outside EnergiBridge samples [{ts[0]}, {ts[-1]}]")
    i = min(max(bisect_right(ts, t), 1), len(ts) - 1)
    ta, tb, va, vb = ts[i - 1], ts[i], vals[i - 1], vals[i]
    return va if tb == ta else va + (vb - va) * (t - ta) / (tb - ta)


RAPL_WRAP_J = 262144.0  # RAPL counters are 32 bit: they overflow at 2^32 * 61.035 uJ = 2^18 J


def unwrap_counter(vals):
    """Make a cumulative RAPL counter monotonic: after an overflow the counter restarts
    from ~0, so every drop is compensated by adding RAPL_WRAP_J to all later samples."""
    out, offset, prev = [], 0.0, None
    for v in vals:
        if prev is not None and not math.isnan(v) and not math.isnan(prev) and v < prev:
            offset += RAPL_WRAP_J
        out.append(v + offset)
        if not math.isnan(v):
            prev = v
    return out


def window_energy(cols, t0, t1):
    ts = cols[TIME_COL]
    pkg = unwrap_counter(cols[PKG_COL])
    e = _interp(ts, pkg, t1) - _interp(ts, pkg, t0)
    dram = cols.get(DRAM_COL)
    dram_used = bool(dram) and not any(math.isnan(v) for v in dram) and max(dram) > 0
    if dram_used:
        dram = unwrap_counter(dram)
        e += _interp(ts, dram, t1) - _interp(ts, dram, t0)
    if e < 0:
        raise ValueError("negative energy (RAPL counter wrap?) - re-run this run")
    return e, dram_used


def window_cpu_and_memory(cols, t0, t1):
    ts = cols[TIME_COL]
    inside = [i for i, t in enumerate(ts) if t0 <= t <= t1]
    if not inside:
        raise ValueError("no EnergiBridge samples inside the measurement window")
    cpu = [cols[CPU_COL][i] for i in inside if not math.isnan(cols[CPU_COL][i])]
    mem = [cols[MEM_COL][i] for i in inside]
    before = [i for i, t in enumerate(ts) if t <= t0]
    baseline = cols[MEM_COL][before[-1]] if before else mem[0]
    return sum(cpu) / len(cpu), max(mem) - baseline


# ------------------------------------------------------------- config -------
class RunnerConfig:
    ROOT_DIR = SCRIPT_DIR
    name = f"json_energy_{BLOCK.replace('-', '_')}" + ("_dry" if DRY_RUN else "")
    results_output_path = PROJECT_ROOT / "results"
    operation_type = OperationType.AUTO
    time_between_runs_in_ms = 0        # the cool-down happens inside start_run
    experiment_path = None             # set by the framework

    def __init__(self):
        EventSubscriptionController.subscribe_to_multiple_events([
            (RunnerEvents.BEFORE_EXPERIMENT, self.before_experiment),
            (RunnerEvents.BEFORE_RUN, self.before_run),
            (RunnerEvents.START_RUN, self.start_run),
            (RunnerEvents.START_MEASUREMENT, self.start_measurement),
            (RunnerEvents.INTERACT, self.interact),
            (RunnerEvents.STOP_MEASUREMENT, self.stop_measurement),
            (RunnerEvents.STOP_RUN, self.stop_run),
            (RunnerEvents.POPULATE_RUN_DATA, self.populate_run_data),
            (RunnerEvents.AFTER_EXPERIMENT, self.after_experiment),
        ])
        self._proc = self._log = self._p_idle = None
        self._pregenerated_rows = self._load_pregenerated_table()

    # ---- run table ------------------------------------------------------
    def create_run_table_model(self):
        model = RunTableModel(
            factors=[FactorModel("library", ["json", "orjson"]),
                     FactorModel("operation", ["dumps", "loads"]),
                     FactorModel("payload", list(PAYLOADS))],
            repetitions=REPETITIONS, data_columns=DATA_COLUMNS)
        original, pre = model.generate_experiment_run_table, self._pregenerated_rows

        def generate():
            """Keep the framework's row objects, but in the pre-generated order."""
            by_id = {row["__run_id"]: row for row in original()}
            ordered = []
            for row in pre:
                g = by_id.get(row["__run_id"])
                if g is None or any(str(g[k]) != row[k] for k in ("library", "operation", "payload")):
                    raise ValueError(f"{row['__run_id']} does not match the pre-generated run table")
                ordered.append(g)
            return ordered

        model.generate_experiment_run_table = generate
        return model

    def _load_pregenerated_table(self):
        with open(RUN_TABLE, newline="") as f:
            rows = list(csv.DictReader(f))
        counts = Counter((r["library"], r["operation"], r["payload"]) for r in rows)
        if len(rows) != EXPECTED_RUNS or set(counts.values()) != {REPETITIONS}:
            raise ValueError(f"{RUN_TABLE}: expected {EXPECTED_RUNS} runs, {REPETITIONS} per configuration")
        if DRY_RUN:  # first run of each library x operation combination
            first = {}
            for r in rows:
                first.setdefault((r["library"], r["operation"]), r)
            rows = list(first.values())
        return rows

    # ---- setup phase (plan 5.3) -------------------------------------------
    def before_experiment(self):
        import orjson
        if platform.python_version() != EXPECTED_PYTHON:
            raise RuntimeError(f"Python {platform.python_version()} != pinned {EXPECTED_PYTHON}")
        if orjson.__version__ != EXPECTED_ORJSON:
            raise RuntimeError(f"orjson {orjson.__version__} != pinned {EXPECTED_ORJSON}")
        if os.getloadavg()[0] > MAX_IDLE_LOADAVG:
            raise RuntimeError(f"server not idle (load average {os.getloadavg()[0]:.2f})")
        if json.decoder.c_scanstring is None or json.encoder.c_make_encoder is None:
            raise RuntimeError("json C accelerator is not active")

        for name, path in PAYLOADS.items():   # both libraries must produce equivalent outputs
            raw = path.read_bytes()
            obj = json.loads(raw)
            out_json = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            if not (json.loads(out_json) == orjson.loads(orjson.dumps(obj)) == obj
                    and orjson.loads(raw) == obj):
                raise RuntimeError(f"json/orjson outputs differ for payload '{name}'")

        if not DRY_RUN:
            self._thermal_warmup()

    def _thermal_warmup(self, max_wait_s=1800):
        """CPU-bound load on the benchmark core until the package temperature settles (+-1 C / min)."""
        zones = sorted(glob("/sys/class/thermal/thermal_zone*"),
                       key=lambda z: int(z.rsplit("thermal_zone", 1)[1]))
        temp_file = next((Path(z) / "temp" for z in zones
                          if (Path(z) / "type").read_text().strip() == "x86_pkg_temp"), None)
        if temp_file is None:
            raise RuntimeError("no x86_pkg_temp thermal zone found")
        burner = subprocess.Popen(["taskset", "-c", str(PIN_CORE), sys.executable, "-c",
                                   "while True: pass"])
        history, start = deque(), time.time()
        try:
            while time.time() - start < max_wait_s:
                now = time.time()
                history.append((now, int(temp_file.read_text()) / 1000.0))
                while now - history[0][0] > 60:
                    history.popleft()
                temps = [t for _, t in history]
                if now - history[0][0] >= 55 and max(temps) - min(temps) <= 1.0:
                    return
                time.sleep(5)
            raise RuntimeError("package temperature did not stabilise")
        finally:
            burner.terminate()
            burner.wait()

    # ---- per-run events -------------------------------------------------
    def before_run(self):
        pass

    def start_run(self, context: RunnerContext):
        """Cool-down; its last IDLE_SAMPLE_S seconds are sampled to estimate P_idle."""
        time.sleep(COOLDOWN_S - IDLE_SAMPLE_S)
        idle_csv = context.run_dir / "idle.csv"
        subprocess.run(["energibridge", "-o", str(idle_csv), "--summary", "sleep", str(IDLE_SAMPLE_S)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cols = read_samples(idle_csv)
        ts = cols[TIME_COL]
        self._p_idle = window_energy(cols, ts[0], ts[-1])[0] / ((ts[-1] - ts[0]) / 1000.0)

    def start_measurement(self, context: RunnerContext):
        """EnergiBridge starts a fresh core-pinned Python process; warm-up and the
        measurement window happen inside benchmark.py."""
        v = getattr(context, "execute_run", None) or context.run_variation  # name varies by version
        work = (["--volume-bytes", str(VOLUME_BYTES)] if BLOCK == "synthetic"
                else ["--iterations", str(REAL_WORLD_ITERATIONS[v["payload"]])])
        cmd = ["energibridge", "-o", str(context.run_dir / "energibridge.csv"), "--summary",
               "taskset", "-c", str(PIN_CORE), sys.executable, str(BENCHMARK_SCRIPT),
               "--library", v["library"], "--operation", v["operation"],
               "--payload-file", str(PAYLOADS[v["payload"]]), *work,
               "--result-file", str(context.run_dir / "benchmark.json")]
        self._log = open(context.run_dir / "energibridge_stdout.log", "w")
        self._proc = subprocess.Popen(cmd, stdout=self._log, stderr=subprocess.STDOUT)

    def interact(self, context: RunnerContext):
        self._proc.wait()

    def stop_measurement(self, context: RunnerContext):
        self._log.close()
        if self._proc.returncode != 0:
            raise RuntimeError(f"benchmark failed (rc={self._proc.returncode}); "
                               f"see {context.run_dir / 'energibridge_stdout.log'}")

    def stop_run(self, context: RunnerContext):
        pass

    def populate_run_data(self, context: RunnerContext):
        bench = json.loads((context.run_dir / "benchmark.json").read_text())
        cols = read_samples(context.run_dir / "energibridge.csv")
        t0, t1 = bench["start_time_ms"], bench["end_time_ms"]
        energy, _ = window_energy(cols, t0, t1)
        cpu, peak_mem = window_cpu_and_memory(cols, t0, t1)
        row = {"execution_time_s": bench["execution_time_s"], "cpu_utilisation_pct": cpu,
               "peak_memory_bytes": peak_mem, "energy_J": energy,
               "idle_power_W": self._p_idle}
        if BLOCK == "real-world":  # peak RSS of the process minus its baseline before the payload load
            row["peak_rss_bytes"] = bench["maxrss_after_bytes"] - bench["maxrss_start_bytes"]
        return row

    def after_experiment(self):
        pass