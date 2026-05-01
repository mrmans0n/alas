use std::path::Path;

use alas::app::{DetectedLanguage, detect_language};

#[test]
fn detects_common_source_extensions() {
    let cases = [
        ("src/main.rs", DetectedLanguage::Rust),
        ("app.tsx", DetectedLanguage::TypeScript),
        ("index.mjs", DetectedLanguage::JavaScript),
        ("config.json", DetectedLanguage::Json),
        ("pyproject.toml", DetectedLanguage::Toml),
        ("workflow.yml", DetectedLanguage::Yaml),
        ("script.py", DetectedLanguage::Python),
        ("README.md", DetectedLanguage::Markdown),
        ("install.sh", DetectedLanguage::Shell),
        ("style.css", DetectedLanguage::Css),
        ("index.html", DetectedLanguage::Html),
        ("notes.txt", DetectedLanguage::PlainText),
        ("unknown.xyz", DetectedLanguage::Unknown),
    ];

    for (path, language) in cases {
        assert_eq!(detect_language(Path::new(path)), language, "{path}");
    }
}

#[test]
fn detects_special_filenames() {
    let cases = [
        ("Cargo.toml", DetectedLanguage::Toml),
        ("package.json", DetectedLanguage::Json),
        ("Dockerfile", DetectedLanguage::Shell),
        ("Makefile", DetectedLanguage::PlainText),
        (".gitignore", DetectedLanguage::PlainText),
    ];

    for (path, language) in cases {
        assert_eq!(detect_language(Path::new(path)), language, "{path}");
    }
}
