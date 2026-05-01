use std::borrow::Cow;

use crate::app::DetectedLanguage;
use tree_sitter_highlight::{
    Error as TreeSitterError, Highlight, HighlightConfiguration, HighlightEvent, Highlighter,
};

const HIGHLIGHT_NAMES: &[&str] = &[
    "attribute",
    "comment",
    "constant",
    "constant.builtin",
    "constructor",
    "function",
    "function.builtin",
    "keyword",
    "number",
    "operator",
    "property",
    "punctuation",
    "punctuation.bracket",
    "punctuation.delimiter",
    "string",
    "string.special",
    "type",
    "type.builtin",
    "variable",
    "variable.builtin",
    "variable.parameter",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightedSource {
    pub lines: Vec<HighlightedLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightedLine {
    pub spans: Vec<HighlightedSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightedSpan {
    pub text: String,
    pub style: SourceTokenStyle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceTokenStyle {
    Plain,
    Keyword,
    String,
    Number,
    Comment,
    Function,
    Type,
    Property,
    Punctuation,
    Constant,
    Variable,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HighlightError {
    #[error("syntax highlighting is unavailable for {0}")]
    Unsupported(&'static str),
    #[error("syntax highlighting failed: {0}")]
    Failed(String),
}

pub fn highlight_source(
    text: &str,
    language: DetectedLanguage,
) -> Result<HighlightedSource, HighlightError> {
    let Some(mut config) = highlight_config(language)? else {
        return Err(HighlightError::Unsupported(language.label()));
    };
    config.configure(HIGHLIGHT_NAMES);

    let text = normalize_line_endings(text);
    let text = text.as_ref();

    let mut highlighter = Highlighter::new();
    let events = highlighter
        .highlight(&config, text.as_bytes(), None, |_| None)
        .map_err(highlight_error)?;

    let mut active_style = SourceTokenStyle::Plain;
    let mut stack = Vec::new();
    let mut spans = Vec::new();

    for event in events {
        match event.map_err(highlight_error)? {
            HighlightEvent::Source { start, end } => {
                if start < end {
                    push_text_span(&mut spans, &text[start..end], active_style);
                }
            }
            HighlightEvent::HighlightStart(highlight) => {
                stack.push(active_style);
                active_style = style_for_highlight(highlight);
            }
            HighlightEvent::HighlightEnd => {
                active_style = stack.pop().unwrap_or(SourceTokenStyle::Plain);
            }
        }
    }

    Ok(split_spans_into_lines(spans))
}

fn normalize_line_endings(text: &str) -> Cow<'_, str> {
    if text.contains("\r\n") {
        Cow::Owned(text.replace("\r\n", "\n"))
    } else {
        Cow::Borrowed(text)
    }
}

fn highlight_config(
    language: DetectedLanguage,
) -> Result<Option<HighlightConfiguration>, HighlightError> {
    match language {
        DetectedLanguage::Rust => HighlightConfiguration::new(
            tree_sitter_rust::LANGUAGE.into(),
            "rust",
            tree_sitter_rust::HIGHLIGHTS_QUERY,
            tree_sitter_rust::INJECTIONS_QUERY,
            "",
        )
        .map(Some)
        .map_err(|error| HighlightError::Failed(error.to_string())),
        DetectedLanguage::Json => HighlightConfiguration::new(
            tree_sitter_json::LANGUAGE.into(),
            "json",
            tree_sitter_json::HIGHLIGHTS_QUERY,
            "",
            "",
        )
        .map(Some)
        .map_err(|error| HighlightError::Failed(error.to_string())),
        DetectedLanguage::TypeScript
        | DetectedLanguage::JavaScript
        | DetectedLanguage::Toml
        | DetectedLanguage::Yaml
        | DetectedLanguage::Python
        | DetectedLanguage::Markdown
        | DetectedLanguage::Shell
        | DetectedLanguage::Css
        | DetectedLanguage::Html
        | DetectedLanguage::PlainText
        | DetectedLanguage::Unknown => Ok(None),
    }
}

fn style_for_highlight(highlight: Highlight) -> SourceTokenStyle {
    let name = HIGHLIGHT_NAMES
        .get(highlight.0)
        .copied()
        .unwrap_or_default();

    match name {
        "keyword" | "operator" => SourceTokenStyle::Keyword,
        "string" | "string.special" => SourceTokenStyle::String,
        "number" => SourceTokenStyle::Number,
        "comment" => SourceTokenStyle::Comment,
        "function" | "function.builtin" | "constructor" => SourceTokenStyle::Function,
        "type" | "type.builtin" => SourceTokenStyle::Type,
        "property" => SourceTokenStyle::Property,
        "punctuation" | "punctuation.bracket" | "punctuation.delimiter" => {
            SourceTokenStyle::Punctuation
        }
        "constant" | "constant.builtin" => SourceTokenStyle::Constant,
        "variable" | "variable.builtin" | "variable.parameter" => SourceTokenStyle::Variable,
        _ => SourceTokenStyle::Plain,
    }
}

fn push_text_span(spans: &mut Vec<HighlightedSpan>, text: &str, style: SourceTokenStyle) {
    if text.is_empty() {
        return;
    }
    if let Some(last) = spans.last_mut()
        && last.style == style
    {
        last.text.push_str(text);
        return;
    }
    spans.push(HighlightedSpan {
        text: text.to_string(),
        style,
    });
}

fn split_spans_into_lines(spans: Vec<HighlightedSpan>) -> HighlightedSource {
    let mut lines = vec![HighlightedLine { spans: Vec::new() }];

    for span in spans {
        for (index, part) in span.text.split('\n').enumerate() {
            if index > 0 {
                lines.push(HighlightedLine { spans: Vec::new() });
            }
            if !part.is_empty() {
                lines
                    .last_mut()
                    .expect("at least one line")
                    .spans
                    .push(HighlightedSpan {
                        text: part.to_string(),
                        style: span.style,
                    });
            }
        }
    }

    HighlightedSource { lines }
}

fn highlight_error(error: TreeSitterError) -> HighlightError {
    HighlightError::Failed(error.to_string())
}
