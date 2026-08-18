#![no_main]

// ADDITIVE execution target (not part of upstream's jaq-core/fuzz/ crate).
//
// Upstream's own three cargo-fuzz targets (jaq-core/fuzz/fuzz_targets/{parse_tokens,
// load_and_compile, data}.rs) mostly stop at parse/compile: `parse_tokens` only exercises the
// lexer/parser's `Arbitrary`-derived token stream, `load_and_compile` parses+compiles arbitrary
// filter TEXT but never runs it, and `data` runs a FIXED filter (".[]") over an arbitrary
// `String`. None of them drives jaq's actual INTERPRETER (`Filter::run`) against a variety of
// real JSON shapes. This target does: it parses the fuzzer's bytes as a JSON document (the
// jaq_json reader used by the real `jaq` CLI) and evaluates a small, fixed set of standard jq
// filters against it end-to-end (parse the filter -> compile -> execute), draining each filter's
// output stream.
//
// BOUNDEDNESS (see docs/netnew-worker-prompt.md §6b — a hang is worse than a crash, since it
// stops the whole campaign): the fuzzed bytes are the JSON *data*, never the filter TEXT, and the
// filter set below is a small FIXED list of ordinary structural/library filters (recursive
// descent, `keys`, `add`, `tostring`, `length`, `paths`) with no user-defined recursion of our
// own -- so there is no way for the fuzzer to construct a filter like `def f: [f]; f` or
// `repeat(.)` that generates an unbounded/self-referential stream: the *filter* is not fuzzed
// input, only the *data* is. Recursion depth for `..`/`paths` is bounded by the JSON document's
// own nesting depth, which is itself bounded by the fuzzer's input length (a JSON parser can't
// nest deeper than roughly one level per few input bytes) and libFuzzer's max_len. As a second,
// independent belt-and-braces bound, every filter's output iterator is capped with `.take(256)`
// so even a filter that legitimately produces a very large (but finite) stream — e.g. `..` over
// a JSON document with many total nodes — cannot make a single iteration run away.
use jaq_core::load::{Arena, File, Loader};
use jaq_core::{data, unwrap_valr, Compiler, Ctx, Vars};
use jaq_json::Val;

use libfuzzer_sys::fuzz_target;

/// Small, fixed library of read-only, structural jq filters. Each only inspects the value it is
/// given (no filesystem/network/allocation-explosive constructs of our own); `?` suppresses the
/// (common, uninteresting) type errors so a mismatched filter/value pairing (e.g. `add?` on a
/// scalar) just yields nothing instead of erroring out.
const FILTERS: &[&str] = &["..", "keys?", "add?", "tostring", "length", "paths?"];

fuzz_target!(|data: &[u8]| {
    let Ok(val) = jaq_json::read::parse_single(data) else {
        return;
    };

    let defs = || jaq_core::defs().chain(jaq_std::defs()).chain(jaq_json::defs());
    let funs = || jaq_core::funs().chain(jaq_std::funs()).chain(jaq_json::funs());

    for &code in FILTERS {
        let program = File { code, path: () };
        let loader = Loader::new(defs());
        let arena = Arena::default();

        let Ok(modules) = loader.load(&arena, program) else {
            continue;
        };
        let Ok(filter) = Compiler::<_, data::JustLut<Val>>::default()
            .with_funs(funs())
            .compile(modules)
        else {
            continue;
        };

        let ctx = Ctx::<data::JustLut<Val>>::new(&filter.lut, Vars::new([]));
        // Bound total work per filter: never pull more than 256 outputs from any single stream.
        for r in filter.id.run((ctx, val.clone())).map(unwrap_valr).take(256) {
            let _ = r;
        }
    }
});
