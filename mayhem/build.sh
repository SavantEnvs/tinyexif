#!/usr/bin/env bash
#
# mayhem/build.sh — build TinyEXIF's libFuzzer harness (fuzz/fuzz_exif.cpp), its run-once
# standalone reproducer, and the upstream demo binary used by the corpus-regression oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image exports
# CC/CXX/LIB_FUZZING_ENGINE/SANITIZER_FLAGS/DEBUG_FLAGS/STANDALONE_FUZZ_MAIN/SRC; the only extra
# dependency (libtinyxml2-dev) is apt-installed in the Dockerfile, so this script needs no network.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Build dirs live under make/ because upstream's .gitignore already covers it (SPEC §6.2 item 16).
rm -rf make/fuzz make/tests

# 1) The library, instrumented with ASan+UBSan (halting), DWARF-3 and SanitizerCoverage so the fuzzer
#    gets feedback from the parser itself. Built static; the demo is not needed here.
cmake -S . -B make/fuzz -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize-coverage=inline-8bit-counters,indirect-calls,trace-cmp,pc-table" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_DEMO=OFF -DBUILD_FUZZER=OFF
cmake --build make/fuzz -j"$MAYHEM_JOBS" --target TinyEXIF

# 2) The harness (upstream's own fuzz/fuzz_exif.cpp) twice: libFuzzer engine + standalone driver.
#    LSan is turned off at build time (mayhem/lsan_off.cc): leaks are not what this fleet hunts.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 -c mayhem/lsan_off.cc -o make/fuzz/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 $LIB_FUZZING_ENGINE \
    -I"$SRC" fuzz/fuzz_exif.cpp make/fuzz/lsan_off.o make/fuzz/libTinyEXIF.a -ltinyxml2 \
    -o /mayhem/fuzz_exif
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o make/fuzz/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 \
    -I"$SRC" fuzz/fuzz_exif.cpp make/fuzz/standalone_main.o make/fuzz/lsan_off.o make/fuzz/libTinyEXIF.a -ltinyxml2 \
    -o /mayhem/fuzz_exif-standalone

# 3) The upstream demo with NORMAL flags (no sanitizers) for mayhem/test.sh's TestSamples.py oracle.
cmake -S . -B make/tests -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_DEMO=ON -DBUILD_FUZZER=OFF
cmake --build make/tests -j"$MAYHEM_JOBS" --target TinyEXIFdemo
