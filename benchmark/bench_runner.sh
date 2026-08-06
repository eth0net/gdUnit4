#!/bin/bash
# GdUnit4 test-runner benchmark.
#
# Measures the headless CLI runner against a target Godot project, splitting the
# GdUnit work into discovery vs execution phases (via the GDUNIT_BENCH=1 markers
# emitted by GdUnitTestCIRunner / GdUnitTestSessionRunner) and reporting medians
# across N iterations as a markdown table.
#
# It syncs this repo's addons/gdUnit4 into the target project before running, so
# the numbers reflect the addon revision currently checked out here.
#
# Usage:
#   benchmark/bench_runner.sh --godot <godot-bin> --project <path> [--iterations N] [--filter res://test/] [--no-sync]
#
# Example:
#   benchmark/bench_runner.sh \
#     --godot "/Applications/Godot 4.7.1.app/Contents/MacOS/Godot" \
#     --project ../shrine-guardian-bench --iterations 5

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT=""
PROJECT=""
ITERATIONS=5
FILTER="res://test/"
DO_SYNC=1

while [ $# -gt 0 ]; do
	case "$1" in
		--godot) GODOT="$2"; shift 2 ;;
		--project) PROJECT="$2"; shift 2 ;;
		--iterations) ITERATIONS="$2"; shift 2 ;;
		--filter) FILTER="$2"; shift 2 ;;
		--no-sync) DO_SYNC=0; shift ;;
		*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ -n "$GODOT" ] || { echo "--godot is required" >&2; exit 2; }
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }
[ -x "$GODOT" ] || { echo "Godot binary not executable: $GODOT" >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd)"
[ -f "$PROJECT/project.godot" ] || { echo "No project.godot in $PROJECT" >&2; exit 2; }

if [ "$DO_SYNC" = "1" ]; then
	echo "Syncing addons/gdUnit4 -> $PROJECT ..."
	rsync -a --delete "$REPO_ROOT/addons/gdUnit4/" "$PROJECT/addons/gdUnit4/"
fi

# Warm the import cache once so import time is excluded from the timed runs.
echo "Warming import cache ..."
"$GODOT" --headless --import --path "$PROJECT" >/dev/null 2>&1 || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Running $ITERATIONS iteration(s) against $PROJECT (filter: $FILTER) ..."
for i in $(seq 1 "$ITERATIONS"); do
	LOG="$TMP/run_$i.log"
	START=$(python3 -c 'import time; print(time.time())')
	GDUNIT_BENCH=1 "$GODOT" --headless --path "$PROJECT" -s -d \
		--remote-debug tcp://127.0.0.1:0 \
		res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a "$FILTER" -c --ignoreHeadlessMode \
		>"$LOG" 2>&1 || true
	END=$(python3 -c 'import time; print(time.time())')

	disc=$(grep -oE '##BENCH## discovery_usec=[0-9]+' "$LOG" | grep -oE '[0-9]+' | head -1 || echo 0)
	exec=$(grep -oE '##BENCH## execution_usec=[0-9]+' "$LOG" | grep -oE '[0-9]+' | head -1 || echo 0)
	tests=$(grep -oE '##BENCH## discovery_usec=[0-9]+ tests=[0-9]+' "$LOG" | grep -oE 'tests=[0-9]+' | grep -oE '[0-9]+' | head -1 || echo 0)
	wall=$(python3 -c "print(int(($END - $START) * 1000))")
	printf '%s %s %s %s\n' "$disc" "$exec" "$wall" "$tests" >> "$TMP/results.txt"
	printf '  run %d/%d: discovery=%.0fms execution=%.0fms wall=%dms tests=%s\n' \
		"$i" "$ITERATIONS" "$(echo "$disc/1000" | bc -l)" "$(echo "$exec/1000" | bc -l)" "$wall" "$tests"
done

# median of column $1 (1-based) in results.txt, in the column's native unit
median() {
	awk -v c="$1" '{print $c}' "$TMP/results.txt" | sort -n | awk '
		{ a[NR]=$1 }
		END { if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'
}

d_med=$(median 1); e_med=$(median 2); w_med=$(median 3)
tests=$(awk 'NR==1{print $4}' "$TMP/results.txt")
[ "$tests" -gt 0 ] 2>/dev/null || tests=1

d_ms=$(echo "scale=1; $d_med/1000" | bc -l)
e_ms=$(echo "scale=1; $e_med/1000" | bc -l)
gd_ms=$(echo "scale=1; ($d_med+$e_med)/1000" | bc -l)
per_test=$(echo "scale=3; $e_med/$tests/1000" | bc -l)
d_pct=$(echo "scale=1; 100*$d_med/($d_med+$e_med)" | bc -l)

echo
echo "### GdUnit4 runner benchmark"
echo
echo "Project: \`$PROJECT\` | Godot: \`$("$GODOT" --version 2>/dev/null | head -1)\` | tests: $tests | iterations: $ITERATIONS (median)"
echo
echo "| Phase | Median | Per test |"
echo "| --- | ---: | ---: |"
echo "| Discovery | ${d_ms} ms | — |"
echo "| Execution | ${e_ms} ms | ${per_test} ms |"
echo "| GdUnit total (disc+exec) | ${gd_ms} ms | — |"
echo "| Wall clock (incl. boot) | ${w_med} ms | — |"
echo
echo "Discovery is ${d_pct}% of GdUnit work."
