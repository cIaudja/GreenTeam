#!/usr/bin/env bash
# Run several batches back to back.
#   bash experiment-scripts/run_batches.sh real-world 2 3     # batch 2, then batch 3
#   bash experiment-scripts/run_batches.sh synthetic 1
# Run it from inside tmux. Each batch resumes from its own results folder, so after an
# interruption just start the script again with the same arguments.
set -u
BLOCK=$1; shift
cd "$(dirname "$0")/.."
source ~/gl-venv/bin/activate
NAME=json_energy_${BLOCK//-/_}

for b in "$@"; do
  # before_experiment requires the 1-min load average <= 0.5; right after a batch it is still high
  while awk '{exit !($1 > 0.4)}' /proc/loadavg; do sleep 20; done
  echo "=== $(date) starting $BLOCK batch $b ==="
  BATCH=$b EXPERIMENT_BLOCK=$BLOCK python3 ~/experiment-runner/experiment-runner/ experiment-scripts/RunnerConfig.py
  echo "=== $(date) finished batch $b (exit $?), runs still TODO: $(grep -c TODO results/${NAME}_batch${b}of*/run_table.csv) ==="
done