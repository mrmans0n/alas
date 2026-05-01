use alas::app::{DetectedLanguage, SourceTokenStyle, highlight_source};

#[test]
fn highlights_rust_source_with_tree_sitter() {
    let highlighted = highlight_source(
        "fn main() {\n    println!(\"hi\");\n}\n",
        DetectedLanguage::Rust,
    )
    .expect("highlight rust");

    assert!(
        highlighted
            .lines
            .iter()
            .flat_map(|line| line.spans.iter())
            .any(|span| span.style == SourceTokenStyle::Keyword && span.text == "fn")
    );
    assert!(
        highlighted
            .lines
            .iter()
            .flat_map(|line| line.spans.iter())
            .any(|span| span.style == SourceTokenStyle::String && span.text.contains("hi"))
    );
}

#[test]
fn unsupported_languages_fall_back_to_plain_text() {
    let error = highlight_source("hello", DetectedLanguage::PlainText)
        .expect_err("plain text has no highlighter");

    assert!(error.to_string().contains("unavailable"));
}

#[test]
fn highlighted_crlf_lines_do_not_render_carriage_returns() {
    let highlighted =
        highlight_source("fn main() {\r\n}\r\n", DetectedLanguage::Rust).expect("highlight rust");

    assert!(
        highlighted
            .lines
            .iter()
            .flat_map(|line| line.spans.iter())
            .all(|span| !span.text.contains('\r'))
    );
}
