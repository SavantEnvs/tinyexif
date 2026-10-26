#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's corpus-regression gate (TestSamples.py) against the demo binary
# that mayhem/build.sh built with normal flags. TestSamples.py runs TinyEXIFdemo on every Samples/**.jpg
# and diffs exit code + the full parsed-EXIF output against the checked-in Samples/**/*.expected
# golden files, so a no-op/exit(0) program fails every sample.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

DEMO="$SRC/make/tests/TinyEXIFdemo"
[ -x "$DEMO" ] || { echo "missing $DEMO — mayhem/build.sh should have built it" >&2; exit 1; }

out=$(python3 TestSamples.py --binary "$DEMO" 2>&1)
rc=$?
printf '%s\n' "$out" | tail -n 40
summary=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) samples, \([0-9][0-9]*\) mismatches$/\1 \2/p' | tail -n1)
if [ -z "$summary" ]; then
  echo "TestSamples.py produced no summary line (rc=$rc)" >&2
  emit_ctrf "tinyexif-testsamples" 0 1 0
  exit $?
fi
read -r total bad <<<"$summary"
[ "$bad" -le "$total" ] || bad=$total
emit_ctrf "tinyexif-testsamples" $((total - bad)) "$bad" 0
