#!/usr/bin/env bash
# Runs the test suite as if today were another day.
#
#   bash tool/test_on_another_day.sh 45     # 45 days from now
#   bash tool/test_on_another_day.sh 400
#
# Why: several fixtures carry a fixed date and the app's default window is 30
# days, so a test can pass on the day it is written and fail a month later with
# no change in the code. That is exactly what happened on 2026-11-12, when a
# post dated 2026-11-05 stopped being "this week". A test that needs dated
# rows must open the window (or date its rows from the clock); this script is
# how to check that none was missed.
#
# How: a tiny LD_PRELOAD library (tool/clock_shift.c) shifts only the wall clock
# (CLOCK_REALTIME, gettimeofday, time). Monotonic clocks and timers are left
# alone, so timeouts behave normally. Linux only; needs gcc.
set -euo pipefail
DAYS=${1:-45}
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/ironpin-clock-shift
mkdir -p "$OUT"
gcc -shared -fPIC -O2 -o "$OUT/libshift.so" tool/clock_shift.c -ldl
echo "Running the tests $DAYS days from now"
LD_PRELOAD="$OUT/libshift.so" CLOCK_SHIFT_DAYS="$DAYS" \
  flutter test --no-pub --concurrency=1
