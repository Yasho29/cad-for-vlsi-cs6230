#!/usr/bin/env bash
# run_all.sh
#
# Runs the testbench against every (e,m) configuration in Table 3 of the
# assignment, plus a couple of extra samples from the undisclosed
# non-standard range (2<=e<=15, 2<=m<=63) for good measure.
#
# Usage:
#   ./run_all.sh            # 20000 vectors per width
#   ./run_all.sh 5000       # override vector count per width
#
# Run from ~/fpadder/tb. Expects gen_vectors.py, Testbench.bsv here and
# FloatingPointAdder.bsv in ../rtl (adjust RTL_DIR below if different).

set -u   # (deliberately not -e: we want every width to run even if one fails)

# Resolve everything relative to this script, not the caller's current
# directory.  Thus both `cd ~/fpadder/tb && ./run_all.sh` and
# `~/fpadder/tb/run_all.sh` work.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

RTL_DIR="$SCRIPT_DIR/../rtl"
N="${1:-20000}"
SEED_BASE=100

if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 [positive-vector-count]" >&2
  exit 2
fi

for tool in python3 bsc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required command not found: $tool" >&2
    exit 127
  fi
done

if [[ ! -f "$RTL_DIR/FloatingPointAdder.bsv" ]]; then
  echo "Missing RTL source: $RTL_DIR/FloatingPointAdder.bsv" >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/gen_vectors.py" || ! -f "$SCRIPT_DIR/Testbench.bsv" ]]; then
  echo "gen_vectors.py and Testbench.bsv must be beside run_all.sh" >&2
  exit 1
fi

# name  e  m
CONFIGS=(
  "OCP_FP8_E4M3  4  3"
  "binary16      5  10"
  "bfloat16      8  7"
  "binary32      8  23"
  "binary64      11 52"
  "extra_narrow  2  2"
  "extra_wide    15 63"
)

# Use an ordinary indexed array for compatibility with older Bash releases
# that do not support `declare -A` associative arrays.
declare -a RESULTS=()

for entry in "${CONFIGS[@]}"; do
  read -r name e m <<< "$entry"
  seed=$((SEED_BASE + e * 100 + m))

  echo "=================================================================="
  echo ">> $name : e=$e m=$m  (n=$N, seed=$seed)"
  echo "=================================================================="

  python3 gen_vectors.py --e "$e" --m "$m" --n "$N" --seed "$seed" --out . \
    || { RESULTS[${#RESULTS[@]}]="GEN_FAILED"; continue; }

  rm -rf build
  mkdir -p build

  bsc -p .:"$RTL_DIR":+ -u -sim -bdir build -simdir build -info-dir build \
      -g mkTestbench Testbench.bsv > build_log.txt 2>&1
  if [ $? -ne 0 ]; then
    echo "COMPILE FAILED for $name -- see build_log.txt"
    RESULTS[${#RESULTS[@]}]="COMPILE_FAILED"
    continue
  fi

  bsc -sim -bdir build -simdir build -e mkTestbench -o simTestbench \
      >> build_log.txt 2>&1
  if [ $? -ne 0 ]; then
    echo "LINK FAILED for $name -- see build_log.txt"
    RESULTS[${#RESULTS[@]}]="LINK_FAILED"
    continue
  fi

  sim_out=$(./simTestbench)
  echo "$sim_out"

  if echo "$sim_out" | grep -q "ALL VECTORS PASSED"; then
    RESULTS[${#RESULTS[@]}]="PASS"
  else
    RESULTS[${#RESULTS[@]}]="FAIL"
    echo "$sim_out" | grep "^MISMATCH" > "mismatches_${name}.txt"
    echo "  (mismatches saved to mismatches_${name}.txt)"
  fi
done

echo
echo "=================================================================="
echo "SUMMARY"
echo "=================================================================="
result_index=0
for entry in "${CONFIGS[@]}"; do
  read -r name e m <<< "$entry"
  printf "  %-14s e=%-3s m=%-3s  %s\n" \
    "$name" "$e" "$m" "${RESULTS[$result_index]:-NOT_RUN}"
  result_index=$((result_index + 1))
done
