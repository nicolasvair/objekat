#!/bin/sh
# Runs every test_*.py of this folder with the given Python (default: python3).
# Usage: ./run_tests.sh [python]
PY="${1:-python3}"
cd "$(dirname "$0")" || exit 1
status=0
for t in test_*.py; do
    [ -e "$t" ] || continue
    echo "== $t"
    out=$("$PY" -m unittest "${t%.py}" 2>&1)
    rc=$?
    echo "$out" | tail -n 4
    [ "$rc" -eq 0 ] || status=1
done
if [ "$status" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$status"
