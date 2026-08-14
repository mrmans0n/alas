//! C ABI over every tree-sitter grammar Alas bundles.
//!
//! Alas links this crate as a static library and reaches the grammars through
//! two id-keyed lookups. The grammar crates disagree on their Rust API — newer
//! ones expose a `LANGUAGE: LanguageFn` const, older ones a `language()` fn —
//! but all of them compile the same `tree_sitter_<name>` C entry point, so
//! those are declared directly here and the drift never reaches this file.
//!
//! Each grammar crate is pulled into the link graph by its query const in
//! `QUERIES`. HCL, Dockerfile, and Kotlin expose no query const and need the
//! separate anchor below.

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};

extern "C" {
    fn tree_sitter_bash() -> *const c_void;
    fn tree_sitter_c() -> *const c_void;
    fn tree_sitter_cpp() -> *const c_void;
    fn tree_sitter_css() -> *const c_void;
    fn tree_sitter_dockerfile() -> *const c_void;
    fn tree_sitter_go() -> *const c_void;
    fn tree_sitter_hcl() -> *const c_void;
    fn tree_sitter_html() -> *const c_void;
    fn tree_sitter_java() -> *const c_void;
    fn tree_sitter_javascript() -> *const c_void;
    fn tree_sitter_json() -> *const c_void;
    fn tree_sitter_kotlin() -> *const c_void;
    fn tree_sitter_lua() -> *const c_void;
    fn tree_sitter_markdown() -> *const c_void;
    fn tree_sitter_markdown_inline() -> *const c_void;
    fn tree_sitter_php() -> *const c_void;
    fn tree_sitter_php_only() -> *const c_void;
    fn tree_sitter_python() -> *const c_void;
    fn tree_sitter_ruby() -> *const c_void;
    fn tree_sitter_rust() -> *const c_void;
    fn tree_sitter_swift() -> *const c_void;
    fn tree_sitter_toml() -> *const c_void;
    fn tree_sitter_tsx() -> *const c_void;
    fn tree_sitter_typescript() -> *const c_void;
    fn tree_sitter_yaml() -> *const c_void;
}

/// Upstream tree-sitter-hcl ships no queries, so this one is maintained by
/// Alas. It moved here from `ThirdParty/TreeSitterHCL/queries/highlights.scm`.
const HCL_HIGHLIGHTS: &str = include_str!("../queries/hcl/highlights.scm");

/// tree-sitter-dockerfile packages `queries/highlights.scm` but keeps the
/// const that would expose it commented out, and a crate cannot `include_str!`
/// another crate's sources. Copied verbatim from the crate at the pinned
/// version; refresh it when the dependency moves.
const DOCKERFILE_HIGHLIGHTS: &str = include_str!("../queries/dockerfile/highlights.scm");

/// tree-sitter-kotlin-ng ships no `queries/` directory at all. This is the
/// query Alas shipped from fwcd/tree-sitter-kotlin (the grammar's stale
/// predecessor), carried over because kotlin-ng's node types are compatible —
/// verified by `kotlin_query_compiles_against_kotlin_ng_grammar` actually
/// compiling it against this grammar, not just checking the text is present.
const KOTLIN_HIGHLIGHTS: &str = include_str!("../queries/kotlin/highlights.scm");

/// These three crates' queries are the local consts above, so nothing else
/// here references the crates themselves and the linker is free to drop their
/// objects — leaving `tree_sitter_hcl`, `tree_sitter_dockerfile`, and
/// `tree_sitter_kotlin` unresolved. Touching one const each keeps them in the
/// link graph.
#[used]
static LINK_ANCHORS: [&str; 3] = [
    tree_sitter_hcl::NODE_TYPES,
    tree_sitter_dockerfile::NODE_TYPES,
    tree_sitter_kotlin_ng::NODE_TYPES,
];

type LanguageFn = unsafe extern "C" fn() -> *const c_void;

static LANGUAGES: &[(&str, LanguageFn)] = &[
    ("bash", tree_sitter_bash),
    ("c", tree_sitter_c),
    ("cpp", tree_sitter_cpp),
    ("css", tree_sitter_css),
    ("dockerfile", tree_sitter_dockerfile),
    ("go", tree_sitter_go),
    ("hcl", tree_sitter_hcl),
    ("html", tree_sitter_html),
    ("java", tree_sitter_java),
    ("javascript", tree_sitter_javascript),
    ("json", tree_sitter_json),
    ("kotlin", tree_sitter_kotlin),
    ("lua", tree_sitter_lua),
    ("markdown", tree_sitter_markdown),
    ("markdown_inline", tree_sitter_markdown_inline),
    ("php", tree_sitter_php),
    ("php_only", tree_sitter_php_only),
    ("python", tree_sitter_python),
    ("ruby", tree_sitter_ruby),
    ("rust", tree_sitter_rust),
    ("swift", tree_sitter_swift),
    ("toml", tree_sitter_toml),
    ("tsx", tree_sitter_tsx),
    ("typescript", tree_sitter_typescript),
    ("yaml", tree_sitter_yaml),
];

/// Highlight queries, keyed by language id. `javascript_jsx` is the JSX
/// overlay upstream ships beside the base JavaScript query; Alas merges it in
/// for `.jsx`/`.tsx`. TypeScript and TSX share one upstream query file.
static QUERIES: &[(&str, &str)] = &[
    ("bash", tree_sitter_bash::HIGHLIGHT_QUERY),
    ("c", tree_sitter_c::HIGHLIGHT_QUERY),
    ("cpp", tree_sitter_cpp::HIGHLIGHT_QUERY),
    ("css", tree_sitter_css::HIGHLIGHTS_QUERY),
    ("dockerfile", DOCKERFILE_HIGHLIGHTS),
    ("go", tree_sitter_go::HIGHLIGHTS_QUERY),
    ("hcl", HCL_HIGHLIGHTS),
    ("html", tree_sitter_html::HIGHLIGHTS_QUERY),
    ("java", tree_sitter_java::HIGHLIGHTS_QUERY),
    ("javascript", tree_sitter_javascript::HIGHLIGHT_QUERY),
    ("javascript_jsx", tree_sitter_javascript::JSX_HIGHLIGHT_QUERY),
    ("json", tree_sitter_json::HIGHLIGHTS_QUERY),
    ("kotlin", KOTLIN_HIGHLIGHTS),
    ("lua", tree_sitter_lua::HIGHLIGHTS_QUERY),
    ("markdown", tree_sitter_md::HIGHLIGHT_QUERY_BLOCK),
    ("markdown_inline", tree_sitter_md::HIGHLIGHT_QUERY_INLINE),
    ("php", tree_sitter_php::HIGHLIGHTS_QUERY),
    ("python", tree_sitter_python::HIGHLIGHTS_QUERY),
    ("ruby", tree_sitter_ruby::HIGHLIGHTS_QUERY),
    ("rust", tree_sitter_rust::HIGHLIGHTS_QUERY),
    ("swift", tree_sitter_swift::HIGHLIGHTS_QUERY),
    ("toml", tree_sitter_toml_ng::HIGHLIGHTS_QUERY),
    ("tsx", tree_sitter_typescript::HIGHLIGHTS_QUERY),
    ("typescript", tree_sitter_typescript::HIGHLIGHTS_QUERY),
    ("yaml", tree_sitter_yaml::HIGHLIGHTS_QUERY),
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

    /// `every_query_is_non_empty` only checks the text is present, not that
    /// it is valid for the grammar it ships beside. `KOTLIN_HIGHLIGHTS` is the
    /// one query in this crate not sourced from the grammar's own repo — that
    /// grammar (tree-sitter-kotlin-ng) ships no queries at all, so this one is
    /// hand-written against its node-types.json — and this compiles it for
    /// real against the actual `TSLanguage`, so an incompatible node or field
    /// name fails here, not just in the highlighting output.
    #[test]
    fn kotlin_query_compiles_against_kotlin_ng_grammar() {
        let language: tree_sitter::Language = tree_sitter_kotlin_ng::LANGUAGE.into();
        tree_sitter::Query::new(&language, KOTLIN_HIGHLIGHTS)
            .expect("KOTLIN_HIGHLIGHTS must compile against tree-sitter-kotlin-ng's grammar");
    }

    /// Compiling proves the query is well-formed; it says nothing about
    /// whether any pattern actually matches. Parse a small real Kotlin
    /// snippet and confirm the query fires for the capture categories that
    /// matter most for readability, so a query that "compiles but captures
    /// nothing useful" fails here instead of shipping silently.
    #[test]
    fn kotlin_query_captures_expected_categories_on_real_source() {
        let source = r#"
            package com.alas.sample

            import kotlin.collections.List

            /** Doc comment */
            class Greeter(private val name: String) {
                // line comment
                fun greet(times: Int = 1): String {
                    val prefix = "Hello, "
                    return prefix + name
                }
            }
        "#;

        use tree_sitter::StreamingIterator;

        let language: tree_sitter::Language = tree_sitter_kotlin_ng::LANGUAGE.into();
        let mut parser = tree_sitter::Parser::new();
        parser.set_language(&language).unwrap();
        let tree = parser.parse(source, None).expect("kotlin source must parse");
        assert!(!tree.root_node().has_error(), "kotlin sample has a parse error");

        let query = tree_sitter::Query::new(&language, KOTLIN_HIGHLIGHTS).unwrap();
        let mut cursor = tree_sitter::QueryCursor::new();
        let capture_names = query.capture_names();
        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        let mut matches = cursor.matches(&query, tree.root_node(), source.as_bytes());
        while let Some(m) = matches.next() {
            for c in m.captures {
                seen.insert(capture_names[c.index as usize]);
            }
        }

        for expected in ["keyword", "type", "function", "string", "comment"] {
            assert!(
                seen.iter().any(|c| *c == expected || c.starts_with(&format!("{expected}."))),
                "no capture in {expected}(.*) fired on the sample; seen: {seen:?}"
            );
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
