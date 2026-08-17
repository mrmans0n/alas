//! C ABI over every tree-sitter grammar Alas bundles.
//!
//! Alas links this crate as a static library and reaches the grammars through
//! two id-keyed lookups. The grammar crates disagree on their Rust API — newer
//! ones expose a `LANGUAGE: LanguageFn` const, older ones a `language()` fn —
//! but all of them compile the same `tree_sitter_<name>` C entry point, so
//! those are declared directly here and the drift never reaches this file.
//!
//! Each grammar crate is pulled into the link graph by its query const in
//! `QUERIES`. The crates whose query is vendored here instead — because they
//! expose no query const — reference nothing of their own, so they need the
//! separate `LINK_ANCHORS` below.

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};

extern "C" {
    fn tree_sitter_bash() -> *const c_void;
    fn tree_sitter_c() -> *const c_void;
    fn tree_sitter_c_sharp() -> *const c_void;
    // tree-sitter-clojure-orchard names its entry point after the crate, not
    // after the language.
    fn tree_sitter_clojure_orchard() -> *const c_void;
    fn tree_sitter_cmake() -> *const c_void;
    fn tree_sitter_cpp() -> *const c_void;
    fn tree_sitter_css() -> *const c_void;
    fn tree_sitter_dart() -> *const c_void;
    fn tree_sitter_dockerfile() -> *const c_void;
    fn tree_sitter_elixir() -> *const c_void;
    fn tree_sitter_erlang() -> *const c_void;
    fn tree_sitter_go() -> *const c_void;
    fn tree_sitter_graphql() -> *const c_void;
    fn tree_sitter_groovy() -> *const c_void;
    fn tree_sitter_haskell() -> *const c_void;
    fn tree_sitter_hcl() -> *const c_void;
    fn tree_sitter_html() -> *const c_void;
    fn tree_sitter_ini() -> *const c_void;
    fn tree_sitter_java() -> *const c_void;
    fn tree_sitter_javascript() -> *const c_void;
    fn tree_sitter_json() -> *const c_void;
    fn tree_sitter_julia() -> *const c_void;
    fn tree_sitter_lua() -> *const c_void;
    fn tree_sitter_make() -> *const c_void;
    fn tree_sitter_markdown() -> *const c_void;
    fn tree_sitter_markdown_inline() -> *const c_void;
    fn tree_sitter_objc() -> *const c_void;
    fn tree_sitter_php() -> *const c_void;
    fn tree_sitter_php_only() -> *const c_void;
    fn tree_sitter_powershell() -> *const c_void;
    fn tree_sitter_proto() -> *const c_void;
    fn tree_sitter_python() -> *const c_void;
    fn tree_sitter_r() -> *const c_void;
    fn tree_sitter_ruby() -> *const c_void;
    fn tree_sitter_rust() -> *const c_void;
    fn tree_sitter_scala() -> *const c_void;
    fn tree_sitter_scss() -> *const c_void;
    // The SQL grammar ships in the tree-sitter-sequel crate, but the grammar
    // itself is named `sql`, so that is the symbol its parser.c defines.
    fn tree_sitter_sql() -> *const c_void;
    fn tree_sitter_svelte() -> *const c_void;
    fn tree_sitter_swift() -> *const c_void;
    fn tree_sitter_toml() -> *const c_void;
    fn tree_sitter_tsx() -> *const c_void;
    fn tree_sitter_typescript() -> *const c_void;
    fn tree_sitter_xml() -> *const c_void;
    fn tree_sitter_yaml() -> *const c_void;
    fn tree_sitter_zig() -> *const c_void;
}

/// Upstream tree-sitter-hcl ships no queries, so this one is maintained by
/// Alas. It moved here from `ThirdParty/TreeSitterHCL/queries/highlights.scm`.
const HCL_HIGHLIGHTS: &str = include_str!("../queries/hcl/highlights.scm");

/// tree-sitter-dockerfile packages `queries/highlights.scm` but keeps the
/// const that would expose it commented out, and a crate cannot `include_str!`
/// another crate's sources. Copied verbatim from the crate at the pinned
/// version; refresh it when the dependency moves.
const DOCKERFILE_HIGHLIGHTS: &str = include_str!("../queries/dockerfile/highlights.scm");

/// tree-sitter-julia and tree-sitter-proto both package `queries/highlights.scm`
/// but expose no const for it, and a crate cannot `include_str!` another
/// crate's sources. Copied verbatim from each crate at the pinned version;
/// refresh them when the dependency moves.
const JULIA_HIGHLIGHTS: &str = include_str!("../queries/julia/highlights.scm");
const PROTO_HIGHLIGHTS: &str = include_str!("../queries/proto/highlights.scm");

/// tree-sitter-graphql and tree-sitter-groovy package no `queries/` directory
/// at all — their bindings carry the query consts commented out. These come
/// from nvim-treesitter, which maintains the queries for both grammars, and
/// are held to the same bar as every other query here: the
/// `every_query_compiles_against_its_grammar` test compiles them for real.
const GRAPHQL_HIGHLIGHTS: &str = include_str!("../queries/graphql/highlights.scm");
const GROOVY_HIGHLIGHTS: &str = include_str!("../queries/groovy/highlights.scm");

/// These crates' queries are the local consts above, so nothing else here
/// references the crates themselves and the linker is free to drop their
/// objects — leaving `tree_sitter_hcl`, `tree_sitter_dockerfile`,
/// and friends unresolved. Touching one const each keeps
/// them in the link graph.
#[used]
static LINK_ANCHORS: [&str; 6] = [
    tree_sitter_hcl::NODE_TYPES,
    tree_sitter_dockerfile::NODE_TYPES,
    tree_sitter_julia::NODE_TYPES,
    tree_sitter_proto::NODE_TYPES,
    tree_sitter_graphql::NODE_TYPES,
    tree_sitter_groovy::NODE_TYPES,
];

type LanguageFn = unsafe extern "C" fn() -> *const c_void;

static LANGUAGES: &[(&str, LanguageFn)] = &[
    ("bash", tree_sitter_bash),
    ("c", tree_sitter_c),
    ("clojure", tree_sitter_clojure_orchard),
    ("cmake", tree_sitter_cmake),
    ("cpp", tree_sitter_cpp),
    ("csharp", tree_sitter_c_sharp),
    ("css", tree_sitter_css),
    ("dart", tree_sitter_dart),
    ("dockerfile", tree_sitter_dockerfile),
    ("elixir", tree_sitter_elixir),
    ("erlang", tree_sitter_erlang),
    ("go", tree_sitter_go),
    ("graphql", tree_sitter_graphql),
    ("groovy", tree_sitter_groovy),
    ("haskell", tree_sitter_haskell),
    ("hcl", tree_sitter_hcl),
    ("html", tree_sitter_html),
    ("ini", tree_sitter_ini),
    ("java", tree_sitter_java),
    ("javascript", tree_sitter_javascript),
    ("json", tree_sitter_json),
    ("julia", tree_sitter_julia),
    ("lua", tree_sitter_lua),
    ("make", tree_sitter_make),
    ("markdown", tree_sitter_markdown),
    ("markdown_inline", tree_sitter_markdown_inline),
    ("objc", tree_sitter_objc),
    ("php", tree_sitter_php),
    ("php_only", tree_sitter_php_only),
    ("powershell", tree_sitter_powershell),
    ("proto", tree_sitter_proto),
    ("python", tree_sitter_python),
    ("r", tree_sitter_r),
    ("ruby", tree_sitter_ruby),
    ("rust", tree_sitter_rust),
    ("scala", tree_sitter_scala),
    ("scss", tree_sitter_scss),
    ("sql", tree_sitter_sql),
    ("svelte", tree_sitter_svelte),
    ("swift", tree_sitter_swift),
    ("toml", tree_sitter_toml),
    ("tsx", tree_sitter_tsx),
    ("typescript", tree_sitter_typescript),
    ("xml", tree_sitter_xml),
    ("yaml", tree_sitter_yaml),
    ("zig", tree_sitter_zig),
];

/// Highlight queries, keyed by language id. `javascript_jsx` is the JSX
/// overlay upstream ships beside the base JavaScript query; Alas merges it in
/// for `.jsx`/`.tsx`. TypeScript and TSX share one upstream query file.
static QUERIES: &[(&str, &str)] = &[
    ("bash", tree_sitter_bash::HIGHLIGHT_QUERY),
    ("c", tree_sitter_c::HIGHLIGHT_QUERY),
    ("clojure", tree_sitter_clojure_orchard::HIGHLIGHTS_QUERY),
    ("cmake", tree_sitter_cmake::HIGHLIGHTS_QUERY),
    ("cpp", tree_sitter_cpp::HIGHLIGHT_QUERY),
    ("csharp", tree_sitter_c_sharp::HIGHLIGHTS_QUERY),
    ("css", tree_sitter_css::HIGHLIGHTS_QUERY),
    ("dart", tree_sitter_dart::HIGHLIGHTS_QUERY),
    ("dockerfile", DOCKERFILE_HIGHLIGHTS),
    ("elixir", tree_sitter_elixir::HIGHLIGHTS_QUERY),
    ("erlang", tree_sitter_erlang::HIGHLIGHTS_QUERY),
    ("go", tree_sitter_go::HIGHLIGHTS_QUERY),
    ("graphql", GRAPHQL_HIGHLIGHTS),
    ("groovy", GROOVY_HIGHLIGHTS),
    ("haskell", tree_sitter_haskell::HIGHLIGHTS_QUERY),
    ("hcl", HCL_HIGHLIGHTS),
    ("html", tree_sitter_html::HIGHLIGHTS_QUERY),
    ("ini", tree_sitter_ini::HIGHLIGHTS_QUERY),
    ("java", tree_sitter_java::HIGHLIGHTS_QUERY),
    ("javascript", tree_sitter_javascript::HIGHLIGHT_QUERY),
    ("javascript_jsx", tree_sitter_javascript::JSX_HIGHLIGHT_QUERY),
    ("json", tree_sitter_json::HIGHLIGHTS_QUERY),
    ("julia", JULIA_HIGHLIGHTS),
    ("lua", tree_sitter_lua::HIGHLIGHTS_QUERY),
    ("make", tree_sitter_make::HIGHLIGHTS_QUERY),
    ("markdown", tree_sitter_md::HIGHLIGHT_QUERY_BLOCK),
    ("markdown_inline", tree_sitter_md::HIGHLIGHT_QUERY_INLINE),
    ("objc", tree_sitter_objc::HIGHLIGHTS_QUERY),
    ("php", tree_sitter_php::HIGHLIGHTS_QUERY),
    ("powershell", tree_sitter_powershell::HIGHLIGHTS_QUERY),
    ("proto", PROTO_HIGHLIGHTS),
    ("python", tree_sitter_python::HIGHLIGHTS_QUERY),
    ("r", tree_sitter_r::HIGHLIGHTS_QUERY),
    ("ruby", tree_sitter_ruby::HIGHLIGHTS_QUERY),
    ("rust", tree_sitter_rust::HIGHLIGHTS_QUERY),
    ("scala", tree_sitter_scala::HIGHLIGHTS_QUERY),
    ("scss", tree_sitter_scss::HIGHLIGHTS_QUERY),
    ("sql", tree_sitter_sequel::HIGHLIGHTS_QUERY),
    ("svelte", tree_sitter_svelte::HIGHLIGHT_QUERY),
    ("swift", tree_sitter_swift::HIGHLIGHTS_QUERY),
    ("toml", tree_sitter_toml_ng::HIGHLIGHTS_QUERY),
    ("tsx", tree_sitter_typescript::HIGHLIGHTS_QUERY),
    ("typescript", tree_sitter_typescript::HIGHLIGHTS_QUERY),
    ("xml", tree_sitter_xml::XML_HIGHLIGHT_QUERY),
    ("yaml", tree_sitter_yaml::HIGHLIGHTS_QUERY),
    ("zig", tree_sitter_zig::HIGHLIGHTS_QUERY),
];

/// Returns the `TSLanguage *` for `id`, or null when `id` is unknown.
///
/// # Safety
/// `id` must be null or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn alas_ts_language(id: *const c_char) -> *const c_void {
    let Some(key) = str_from_c(id) else {
        return std::ptr::null();
    };
    match LANGUAGES.iter().find(|(name, _)| *name == key) {
        Some((_, entry)) => entry(),
        None => std::ptr::null(),
    }
}

/// Returns the highlight query for `id` and writes its byte length to
/// `out_len`, or null when `id` has no query. The bytes are static UTF-8 and
/// are *not* NUL-terminated — always read exactly `out_len` bytes.
///
/// # Safety
/// `id` must be null or a valid NUL-terminated C string; `out_len` must be
/// null or point to a writable `usize`.
#[no_mangle]
pub unsafe extern "C" fn alas_ts_query(id: *const c_char, out_len: *mut usize) -> *const u8 {
    if !out_len.is_null() {
        *out_len = 0;
    }
    let Some(key) = str_from_c(id) else {
        return std::ptr::null();
    };
    match QUERIES.iter().find(|(name, _)| *name == key) {
        Some((_, query)) => {
            if !out_len.is_null() {
                *out_len = query.len();
            }
            query.as_ptr()
        }
        None => std::ptr::null(),
    }
}

unsafe fn str_from_c<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn language(id: &str) -> *const c_void {
        let c = CString::new(id).unwrap();
        unsafe { alas_ts_language(c.as_ptr()) }
    }

    fn query(id: &str) -> Option<&'static str> {
        let c = CString::new(id).unwrap();
        let mut len = 0usize;
        let ptr = unsafe { alas_ts_query(c.as_ptr(), &mut len) };
        if ptr.is_null() {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        Some(std::str::from_utf8(bytes).unwrap())
    }

    #[test]
    fn every_language_resolves() {
        for (id, _) in LANGUAGES {
            assert!(!language(id).is_null(), "{id} resolved to null");
        }
    }

    #[test]
    fn every_query_is_non_empty() {
        for (id, _) in QUERIES {
            let text = query(id).unwrap_or_else(|| panic!("{id} has no query"));
            assert!(!text.trim().is_empty(), "{id} query is empty");
        }
    }

    /// Every grammar except `php_only` — which reuses the PHP query with an
    /// Alas-side edit — must ship a query, or highlighting silently degrades
    /// to plain text for that language.
    #[test]
    fn every_language_has_a_query_except_php_only() {
        for (id, _) in LANGUAGES {
            if *id == "php_only" {
                continue;
            }
            assert!(query(id).is_some(), "{id} has no query");
        }
    }

    /// Turns one of our raw entry points back into a `tree_sitter::Language`
    /// so a query can be compiled against it.
    fn language_handle(entry: LanguageFn) -> tree_sitter::Language {
        // `LanguageFn::from_raw` wants `-> *const ()` where our table stores
        // `-> *const c_void`; the two are the same pointer, so this only
        // reconciles the declared return type.
        let raw: unsafe extern "C" fn() -> *const () = unsafe { std::mem::transmute(entry) };
        unsafe { tree_sitter_language::LanguageFn::from_raw(raw) }.into()
    }

    /// The one test that would actually catch a broken grammar addition.
    /// `every_query_is_non_empty` proves only that text is present;
    /// this compiles each language's own query against its own `TSLanguage`,
    /// so a query naming a node the grammar doesn't have — the normal failure
    /// mode when a vendored `.scm` drifts from its grammar, or when a grammar
    /// is bumped past its query — fails here instead of silently degrading
    /// that language to plain text in the app.
    ///
    /// `php_only` is skipped: its query is derived from PHP's on the Alas side
    /// (the `php_tag` pattern is stripped), so the unmodified text genuinely
    /// does not compile against that grammar.
    #[test]
    fn every_query_compiles_against_its_grammar() {
        for (id, entry) in LANGUAGES {
            if *id == "php_only" {
                continue;
            }
            let text = query(id).unwrap_or_else(|| panic!("{id} has no query"));
            let language = language_handle(*entry);
            let compiled = match tree_sitter::Query::new(&language, text) {
                Ok(compiled) => compiled,
                Err(error) => panic!("{id} query does not compile against its grammar: {error:?}"),
            };
            // A query can compile and still be inert — an `.scm` that lost its
            // body, or one whose patterns were all stripped, highlights
            // nothing while looking healthy to every other test here.
            assert!(
                compiled.pattern_count() > 0,
                "{id} query compiles but contains no patterns"
            );
            assert!(
                !compiled.capture_names().is_empty(),
                "{id} query compiles but captures nothing"
            );
        }
    }

    /// Alas does not always highlight a language with its own query alone:
    /// `LanguageRegistry.queryIDsByLanguageID` concatenates a base grammar's
    /// query first for the grammars that extend another (an `; inherits:`
    /// directive nothing in this path honors). Those concatenations have to
    /// compile against the *extending* grammar, which is a stricter condition
    /// than either query passing on its own — a node the base query names but
    /// the extending grammar dropped fails only here.
    ///
    /// This list mirrors `queryIDsByLanguageID`; keep the two in step when
    /// either changes. The Swift side proves the merge is actually wired by
    /// asserting a base-grammar capture shows up in the extending language
    /// (see `LanguageRegistryTests`).
    #[test]
    fn merged_queries_compile_against_the_extending_grammar() {
        let merges: &[(&str, &[&str])] = &[
            ("cpp", &["c", "cpp"]),
            ("objc", &["c", "objc"]),
            ("scss", &["css", "scss"]),
            ("typescript", &["javascript", "typescript"]),
            ("tsx", &["javascript", "javascript_jsx", "tsx"]),
            ("javascript", &["javascript", "javascript_jsx"]),
        ];

        for (id, parts) in merges {
            let combined = parts
                .iter()
                .map(|part| query(part).unwrap_or_else(|| panic!("{part} has no query")))
                .collect::<Vec<_>>()
                .join("\n");
            let (_, entry) = LANGUAGES
                .iter()
                .find(|(name, _)| name == id)
                .unwrap_or_else(|| panic!("{id} is not a registered language"));
            let language = language_handle(*entry);
            if let Err(error) = tree_sitter::Query::new(&language, &combined) {
                panic!("merged query {parts:?} does not compile against {id}: {error:?}");
            }
        }
    }

    #[test]
    fn unknown_and_null_ids_are_handled() {
        assert!(language("nope").is_null());
        assert!(query("nope").is_none());
        unsafe {
            assert!(alas_ts_language(std::ptr::null()).is_null());
            assert!(alas_ts_query(std::ptr::null(), std::ptr::null_mut()).is_null());
        }
    }
}
