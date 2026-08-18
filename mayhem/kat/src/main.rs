//! jaq-mayhem-kat — the known-answer probe used by mayhem/test.sh.
//!
//! Why this exists (SPEC §6.3 / the anti-reward-hacking oracle): `cargo test` alone is
//! explicitly forbidden as the sole oracle (docs/netnew-worker-prompt.md §4) because upstream's
//! own dev-dependency test suite proves only upstream's own assertions, and because the spec
//! wants a small, purpose-built, independently-verifiable, DYNAMICALLY LINKED binary the
//! verify-repo sabotage shim can neuter. This probe:
//!
//!   1. Runs FOUR fixed jq filters over FOUR fixed JSON inputs through jaq's real, public API —
//!      the same load -> compile -> run pipeline documented in jaq-core/src/lib.rs's own doctest
//!      (Loader::load, Compiler::compile, Ctx::new, Filter::run) — so this is exactly the
//!      user-facing evaluation path, not a shortcut around it.
//!   2. Asserts each result is EXACTLY the expected value (panics — nonzero exit — otherwise).
//!   3. Prints `KAT_<NAME>=<value>` lines that mayhem/test.sh matches with `grep -qxF`.
//!
//! A neutered binary (verify-repo's LD_PRELOAD shim `_exit(0)`s it before any of this runs)
//! prints nothing, so every `grep -qxF` in test.sh fails.
use jaq_core::load::{Arena, File, Loader};
use jaq_core::{data, unwrap_valr, Compiler, Ctx, Vars};
use jaq_json::Val;

/// Run `code` over `input` through jaq's real API and collect every output value, formatted with
/// `Val`'s own `Display` (compact JSON text) — panics on any parse/compile/eval error, since every
/// KAT case below is a filter+input pair that is known to succeed.
fn run(code: &str, input: Val) -> Vec<String> {
    let program = File { code, path: () };
    let defs = jaq_core::defs().chain(jaq_std::defs()).chain(jaq_json::defs());
    let funs = jaq_core::funs().chain(jaq_std::funs()).chain(jaq_json::funs());

    let loader = Loader::new(defs);
    let arena = Arena::default();
    let modules = loader
        .load(&arena, program)
        .unwrap_or_else(|e| panic!("KAT: failed to parse {code:?}: {e:?}"));

    let filter = Compiler::<_, data::JustLut<Val>>::default()
        .with_funs(funs)
        .compile(modules)
        .unwrap_or_else(|e| panic!("KAT: failed to compile {code:?}: {e:?}"));

    let ctx = Ctx::<data::JustLut<Val>>::new(&filter.lut, Vars::new([]));
    filter
        .id
        .run((ctx, input))
        .map(unwrap_valr)
        .map(|r| match r {
            Ok(v) => v.to_string(),
            Err(e) => panic!("KAT: {code:?} raised an error: {e:?}"),
        })
        .collect()
}

/// Parse a fixed JSON literal (panics on malformed JSON — every literal below is known-valid).
fn json(s: &str) -> Val {
    jaq_json::read::parse_single(s.as_bytes())
        .unwrap_or_else(|e| panic!("KAT: failed to parse fixed JSON {s:?}: {e:?}"))
}

fn kat(name: &str, code: &str, input: Val, expect: &[&str]) {
    let got = run(code, input);
    assert_eq!(
        got, expect,
        "KAT_{name}: filter {code:?} produced {got:?}, expected {expect:?}"
    );
    println!("KAT_{name}={}", got.join(","));
}

fn main() {
    // 1) field projection over an array of objects.
    kat(
        "PROJECT_FIELD",
        "[.[]|.a]",
        json(r#"[{"a":1},{"a":2}]"#),
        &["[1,2]"],
    );

    // 2) `add` — reduce over the input array's own values.
    kat("ADD", "add", json("[1,2,3]"), &["6"]);

    // 3) `map(f)` — rebuild an array by applying a filter to each element.
    kat("MAP_MUL2", "map(.*2)", json("[1,2,3]"), &["[2,4,6]"]);

    // 4) a string/format builtin (native fn from jaq_std::funs(), not core syntax).
    kat(
        "ASCII_DOWNCASE",
        "ascii_downcase",
        json(r#""HELLO""#),
        &[r#""hello""#],
    );
}
