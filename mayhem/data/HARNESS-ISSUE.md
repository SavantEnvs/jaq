# HARNESS-ISSUE: data — STARVED (target disabled by QA)

## Defect

`jaq-core/fuzz/fuzz_targets/data.rs` (upstream's own, unmodified cargo-fuzz
target) always runs the same fixed filter against the same value shape:

```rust
fuzz_target!(|data: String| {
    let program = File { code: ".[]", path: () };
    let loader = Loader::new([]);
    let arena = Arena::default();
    let modules = loader.load(&arena, program).unwrap();
    let filter = Compiler::default().compile(modules).unwrap();
    let ctx = Ctx::<data::JustLut<_>>::new(&filter.lut, Vars::new([]));
    let _ = filter.id.run((ctx, jaq_json::Val::from(data)));
});
```

The fuzzer's arbitrary string becomes a `jaq_json::Val::Str`, and `.[]`
(iterate) applied to a `Val::Str` is a jq type error **unconditionally**,
regardless of the string's content. There is no byte the fuzzer can produce
that changes which code path is taken past the initial type check — the
interpreter rejects every input identically and immediately.

## Evidence

120s local libFuzzer session, no seed corpus (none exists for this target
by design — `Mayhemfile_data` itself already notes "no seed here would add
real signal"):

- `INITED cov: 1090 ft: 1091 corp: 1/1b`
- `#94  REDUCE cov: 1094 ft: 1095 corp: 2/2b` — converges almost instantly
- **Flat for the entire remainder of the run**: `#2069884 DONE cov: 1094
  ft: 1095 corp: 2/2b`, i.e. **zero new coverage across 2,069,790 further
  executions** (~17,100 exec/s, 121s wall time). `new_units_added: 2` total
  for the whole session.
- No crashes, hangs, or OOMs at any point — it isn't broken, it's just
  saturated after ~2 bytes and then spins uselessly.
- Trivial inputs (empty, 1-byte `A`, 16 random bytes) all run cleanly.

## Attribution

Not a bug — harness used exactly per its documented/intended usage; the
crate's own fuzz suite ships it this way. It simply has no real fuzzing
surface: the filter and the type-error outcome are both fixed, so the
target cannot explore jaq's interpreter (`Filter::run`) against realistic
JSON shapes. The additive `execute` target
(`mayhem/fuzz/fuzz_targets/execute.rs`) was built for exactly this gap —
parses fuzzer bytes as a real JSON document and runs a small fixed *library*
of filters against it end-to-end — and reaches `cov: 5361 / ft: 9209`
(actively growing) in the same 120s budget.

## What a fix would look like

To be worth re-enabling, the harness would need to either fuzz the filter
text too (not just the data), or apply `.[]` (or some varied filter) to a
`Val` shape that isn't unconditionally rejected (e.g. an array/object
constructed from the fuzzer bytes rather than a bare `Val::Str`). As
shipped, it duplicates no useful surface not already covered by `execute`
and `load_and_compile`, and was disabled via `mayhem/Mayhemfile_data`
removal (see `dismissals: dropped-target:data` in `repos/jaq.yaml`).
