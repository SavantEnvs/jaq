#!/usr/bin/env bash
#
# jaq/mayhem/test.sh — RUN the project's own cargo test suite AND the KAT probe, and emit a CTRF
# summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3 / docs/netnew-worker-prompt.md §4). Two parts:
#
#  1) `cargo +stable test --workspace` — jaq's own genuine known-answer suite: ~330 `yields!`/
#     `give`/`gives` assertions across jaq-core/jaq-std/jaq-json/jaq-fmts (parser, compiler, and
#     interpreter behaviour on real jq filters) plus the `jaq` CLI's own golden tests. Real
#     assertions on real computed values, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — docs/netnew-worker-prompt.md §4 forbids relying on `cargo test`
#     ALONE as the oracle. /mayhem/kat is a small, purpose-built, dynamically-linked binary
#     (build.sh asserts `file` reports "dynamically linked", failing the build otherwise) that
#     runs four FIXED jq filters over four FIXED JSON inputs through jaq's real public API
#     (Loader::load -> Compiler::compile -> Ctx::new -> Filter::run — the same pipeline documented
#     in jaq-core/src/lib.rs's own doctest) and panics on any mismatch, printing exact
#     `KAT_<NAME>=<value>` lines. A neutered binary (verify-repo's LD_PRELOAD shim `_exit(0)`s it
#     before any of this runs) prints nothing, so every `grep -qxF` below fails.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export RUSTUP_HOME="${RUSTUP_HOME:-/opt/toolchains/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own cargo test suite (jaq-core/jaq-std/jaq-json/jaq-fmts unit+integration
#       tests + the jaq CLI's golden tests) ─────────────────────────────────────────────────────
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 2
fi

echo "=== running: cargo +stable test --workspace ==="
OUT="$SRC/mayhem-build-test.log"
mkdir -p "$(dirname "$OUT")"
cargo +stable test --workspace --no-fail-fast > "$OUT" 2>&1; rc=$?
tail -80 "$OUT" || true

# Every `test result: ok/FAILED. P passed; F failed; I ignored; ...` line (one per test binary)
# reports real counts; sum them.
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + i ))
done < <(grep -E '^test result:' "$OUT" | sed -E 's/^test result: [a-zA-Z]+\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored;.*/\1 \2 \3/')

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no 'test result:' lines parsed — the suite did not run (cargo exit $rc)" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 1
fi
# A non-zero cargo exit with zero counted failures means a build/harness error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -x ... ]` guard here
# is how a probe silently stops running and the oracle quietly degrades.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed/computed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values, computed once (offline, by hand + double-checked by actually running the
# probe against jaq's real API) — see mayhem/kat/src/main.rs:
#   [.[]|.a]        over [{"a":1},{"a":2}]  -> [1,2]
#   add             over [1,2,3]            -> 6
#   map(.*2)        over [1,2,3]            -> [2,4,6]
#   ascii_downcase  over "HELLO"            -> "hello"
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or the interpreter is broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "field projection: [.[]|.a] over [{\"a\":1},{\"a\":2}]" 'KAT_PROJECT_FIELD=[1,2]'
kat_expect "add over [1,2,3]"                                      'KAT_ADD=6'
kat_expect "map(.*2) over [1,2,3]"                                 'KAT_MAP_MUL2=[2,4,6]'
kat_expect "ascii_downcase over \"HELLO\""                         'KAT_ASCII_DOWNCASE="hello"'

emit_ctrf "cargo-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
