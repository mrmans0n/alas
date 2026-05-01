use std::fs;

use alas::app::{FileLoadError, FileLoader};

#[test]
fn loads_utf8_text_file() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("notes.md");
    fs::write(&path, "hello\nworld").expect("write file");

    let loaded = FileLoader::default()
        .load_source_file(&path)
        .expect("load source file");

    assert_eq!(loaded.text, "hello\nworld");
    assert_eq!(loaded.size_bytes, 11);
    assert_eq!(loaded.line_count, 2);
}

#[test]
fn rejects_directories() {
    let temp = tempfile::tempdir().expect("tempdir");

    let error = FileLoader::default()
        .load_text(temp.path())
        .expect_err("directory should fail");

    assert_eq!(error, FileLoadError::Directory);
}

#[cfg(unix)]
#[test]
fn rejects_non_regular_files() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("pipe");
    let status = std::process::Command::new("mkfifo")
        .arg(&path)
        .status()
        .expect("create fifo");
    assert!(status.success());

    let error = FileLoader::default()
        .load_text(&path)
        .expect_err("fifo should fail before reading");

    assert_eq!(error, FileLoadError::NotRegularFile);
}

#[test]
fn rejects_oversized_files() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("large.txt");
    fs::write(&path, "abcd").expect("write file");

    let error = FileLoader::new(3)
        .load_text(&path)
        .expect_err("oversized file should fail");

    assert_eq!(error, FileLoadError::TooLarge { size: 4, max: 3 });
}

#[test]
fn rejects_non_utf8_files() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("binary.txt");
    fs::write(&path, [0xff, 0xfe]).expect("write file");

    let error = FileLoader::default()
        .load_text(&path)
        .expect_err("invalid UTF-8 should fail");

    assert_eq!(error, FileLoadError::InvalidUtf8);
}

#[test]
fn rejects_binary_nul_sample() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("binary.dat");
    fs::write(&path, [b'a', 0, b'b']).expect("write file");

    let error = FileLoader::default()
        .load_text(&path)
        .expect_err("NUL byte should fail");

    assert_eq!(error, FileLoadError::Binary);
}

#[test]
fn reports_missing_files_as_read_errors() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("missing.txt");

    let error = FileLoader::default()
        .load_text(&path)
        .expect_err("missing file should fail");

    assert!(matches!(error, FileLoadError::Read(_)));
}
