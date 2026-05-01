use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DetectedLanguage {
    Rust,
    TypeScript,
    JavaScript,
    Json,
    Toml,
    Yaml,
    Python,
    Markdown,
    Shell,
    Css,
    Html,
    PlainText,
    Unknown,
}

impl DetectedLanguage {
    pub fn label(self) -> &'static str {
        match self {
            DetectedLanguage::Rust => "Rust",
            DetectedLanguage::TypeScript => "TypeScript",
            DetectedLanguage::JavaScript => "JavaScript",
            DetectedLanguage::Json => "JSON",
            DetectedLanguage::Toml => "TOML",
            DetectedLanguage::Yaml => "YAML",
            DetectedLanguage::Python => "Python",
            DetectedLanguage::Markdown => "Markdown",
            DetectedLanguage::Shell => "Shell",
            DetectedLanguage::Css => "CSS",
            DetectedLanguage::Html => "HTML",
            DetectedLanguage::PlainText => "Plain Text",
            DetectedLanguage::Unknown => "Plain Text",
        }
    }
}

pub fn detect_language(path: &Path) -> DetectedLanguage {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let lower_name = file_name.to_ascii_lowercase();

    match lower_name.as_str() {
        "cargo.toml" => return DetectedLanguage::Toml,
        "package.json" | "tsconfig.json" => return DetectedLanguage::Json,
        "dockerfile" => return DetectedLanguage::Shell,
        "makefile" | ".gitignore" | ".dockerignore" => return DetectedLanguage::PlainText,
        _ => {}
    }

    match path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .as_deref()
    {
        Some("rs") => DetectedLanguage::Rust,
        Some("ts" | "tsx" | "mts" | "cts") => DetectedLanguage::TypeScript,
        Some("js" | "jsx" | "mjs" | "cjs") => DetectedLanguage::JavaScript,
        Some("json" | "jsonc") => DetectedLanguage::Json,
        Some("toml") => DetectedLanguage::Toml,
        Some("yaml" | "yml") => DetectedLanguage::Yaml,
        Some("py" | "pyw") => DetectedLanguage::Python,
        Some("md" | "markdown") => DetectedLanguage::Markdown,
        Some("sh" | "bash" | "zsh" | "fish") => DetectedLanguage::Shell,
        Some("css") => DetectedLanguage::Css,
        Some("html" | "htm") => DetectedLanguage::Html,
        Some("txt" | "text" | "log") => DetectedLanguage::PlainText,
        Some(_) => DetectedLanguage::Unknown,
        None => DetectedLanguage::Unknown,
    }
}
