#!/usr/bin/env bash
#
# jaq/mayhem/build.sh — build jaq's upstream cargo-fuzz targets plus one additive execution
# target as sanitized libFuzzer binaries, plus the project's own test suite and the KAT probe
# used by mayhem/test.sh.
#
# Targets produced (one Mayhemfile each):
#   /mayhem/parse_tokens      — upstream jaq-core/fuzz/fuzz_targets/parse_tokens.rs (unmodified;
#                               Arbitrary-derived Vec<Token> straight into the parser)
#   /mayhem/load_and_compile  — upstream jaq-core/fuzz/fuzz_targets/load_and_compile.rs
#                               (unmodified; raw fuzzer bytes as jq filter TEXT -> load + compile,
#                               never run)
#   /mayhem/data              — upstream jaq-core/fuzz/fuzz_targets/data.rs (unmodified; raw
#                               fuzzer bytes as a JSON *string* Val, run through the FIXED filter
#                               ".[]")
#   /mayhem/execute           — mayhem/fuzz/fuzz_targets/execute.rs (ADDITIVE): the raw fuzzer
#                               bytes are parsed as a JSON *document* and evaluated end-to-end
#                               (parse -> compile -> RUN) through a small fixed library of
#                               standard jq filters — this is the one target that actually drives
#                               jaq's interpreter, which the three upstream targets above mostly
#                               do not (data.rs runs a fixed filter over a Val::Str, which never
#                               reaches the interesting array/object-shaped interpreter paths).
#   /mayhem/kat               — dynamically-linked known-answer probe used by mayhem/test.sh
#
# Two separate cargo-fuzz crate roots are involved, each its OWN cargo workspace:
#   - jaq-core/fuzz/  is upstream's own cargo-fuzz crate. Its Cargo.toml already declares an
#     empty `[workspace] members = ["."]` (upstream's own choice, not ours) specifically so it
#     is NOT swept into the repo root's `[workspace] members = [...]` list — so cargo-fuzz builds
#     it into ITS OWN target dir (jaq-core/fuzz/target/...), not the repo-root target/.
#   - mayhem/fuzz/    is our ADDITIVE cargo-fuzz crate (also its own, separate workspace — see
#     the comment in mayhem/fuzz/Cargo.toml) holding only execute.rs.
#
# NOTE (Rust): rustc ignores $SANITIZER_FLAGS (those are clang/C++ flags baked into the base
# image ENV for C/C++ harnesses) — this cargo-fuzz build's ASan comes from -Zsanitizer=address in
# RUSTFLAGS below, not from $SANITIZER_FLAGS.
#
# DWARF gate (SPEC §6.2 item 10): see mayhem/Dockerfile header for the full anchor-object
# rationale; RUST_DEBUG_FLAGS below threads -Z dwarf-version=3 plus the -Clinker anchor wrapper
# through every fuzz-target build.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME (pinned by
#     the Dockerfile ENV).
#   - The committed Cargo.lock files (mayhem/fuzz/Cargo.lock, mayhem/kat/Cargo.lock; upstream's
#     own jaq-core/fuzz has no committed lock, so cargo resolves it fresh from the now-cached
#     registry) let the offline re-run resolve the SAME dependency graph from that cache with no
#     new network I/O. The rlenv runtime exports CARGO_NET_OFFLINE=true for the re-run, so this
#     script does NOT hard-code --offline (that would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# DWARF<4 gate workaround (SPEC §6.2 item 10; see mayhem/Dockerfile header for the full
# rationale): -Z dwarf-version=3 covers rustc's own CUs; -Clinker=<cc-wrapper> prepends a
# hand-built DWARF3 anchor.o as the FIRST object in every link so it becomes the first CU
# verify-repo's `-m1` check reads, even though the precompiled ASan runtime stays DWARF5 deeper
# in the binary.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we pin it
# explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids ASan backtraces.
FUZZ_RUSTFLAGS="--cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

TRIPLE="x86_64-unknown-linux-gnu"

: "${SANITIZER_FLAGS:=}"

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"

# build_fuzz_target <fuzz-dir> <bin-target-dir> <target-name>
#
# `<bin-target-dir>` is where cargo-fuzz actually writes the release binary — it depends on
# whether `<fuzz-dir>` is its own, separate cargo workspace (writes under `<fuzz-dir>/target/`)
# or a member of some OTHER workspace (writes under that workspace root's `target/`). Both
# `jaq-core/fuzz` and `mayhem/fuzz` here are their OWN workspaces (see header), so both write
# under their own dir — but this repo's root Cargo.toml does NOT list either as a member, so
# there is no ambiguity to guess: verified empirically below, and asserted with `[ -x "$bin" ]` so
# a wrong guess fails loudly instead of "succeeding".
build_fuzz_target() {
  local fuzz_dir="$1" bin_target_dir="$2" target="$3"
  echo "--- building fuzz target: $target (--fuzz-dir $fuzz_dir) ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$fuzz_dir" -O --debug-assertions "$target"
  local bin="$SRC/$bin_target_dir/target/$TRIPLE/release/$target"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$target"
  echo "built /mayhem/$target"
}

# Upstream's own three targets, from upstream's own (unmodified) jaq-core/fuzz/ crate.
build_fuzz_target "jaq-core/fuzz" "jaq-core/fuzz" "parse_tokens"
build_fuzz_target "jaq-core/fuzz" "jaq-core/fuzz" "load_and_compile"
build_fuzz_target "jaq-core/fuzz" "jaq-core/fuzz" "data"

# Our additive execution target, from the separate mayhem/fuzz/ crate.
build_fuzz_target "mayhem/fuzz" "mayhem/fuzz" "execute"

# ── The project's own test suite (NORMAL flags, +stable — see mayhem/Dockerfile comment: the
#    oracle build deliberately avoids the pinned nightly so an unrelated nightly-only
#    dev-dependency quirk can never break the functional oracle) — build only, so
#    mayhem/test.sh just RUNS it. --workspace covers jaq-core/jaq-std/jaq-json/jaq-fmts/
#    jaq-all/jaq/jaq-play; neither jaq-core/fuzz nor mayhem/fuzz is a member of the root
#    workspace (each is its own separate workspace — see header), so this can never accidentally
#    pull in a fuzz crate that needs the nightly -Z flags this normal build deliberately avoids.
echo "=== precompiling: cargo +stable test --workspace --no-run (project's NORMAL flags) ==="
cargo +stable test --workspace --no-run

# ── The KAT probe used by mayhem/test.sh (NORMAL flags, +stable — a functional oracle, not a
#    triage artifact; own workspace so it never touches the upstream root Cargo.toml). ──────────
echo "=== building /mayhem/kat (KAT probe, normal flags) ==="
( cd "$SRC/mayhem/kat" && cargo +stable build --release )
cp "$SRC/mayhem/kat/target/release/kat" /mayhem/kat

# Rust binaries are dynamically linked against glibc by DEFAULT on this target — unlike Go, which
# statically links everything — but assert it explicitly so a toolchain/target change can't
# silently turn the probe static and defeat the verify-repo sabotage check (LD_PRELOAD can only
# neuter a dynamically linked exe).
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

echo "build.sh complete:"
ls -la /mayhem/parse_tokens /mayhem/load_and_compile /mayhem/data /mayhem/execute /mayhem/kat
