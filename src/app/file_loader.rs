use std::{fs, io::Read, path::Path};

pub const MAX_TEXT_FILE_BYTES: u64 = 2 * 1024 * 1024;
const BINARY_SAMPLE_BYTES: usize = 8 * 1024;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FileLoadError {
    #[error("path is a directory")]
    Directory,
    #[error("path is not a regular file")]
    NotRegularFile,
    #[error("file is too large ({size} bytes, max {max} bytes)")]
    TooLarge { size: u64, max: u64 },
    #[error("binary files cannot be previewed")]
    Binary,
    #[error("file is not valid UTF-8")]
    InvalidUtf8,
    #[error("failed to read file: {0}")]
    Read(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedSourceFile {
    pub text: String,
    pub size_bytes: u64,
    pub line_count: usize,
}

#[derive(Debug, Clone, Copy)]
pub struct FileLoader {
    max_bytes: u64,
}

impl Default for FileLoader {
    fn default() -> Self {
        Self {
            max_bytes: MAX_TEXT_FILE_BYTES,
        }
    }
}

impl FileLoader {
    pub fn new(max_bytes: u64) -> Self {
        Self { max_bytes }
    }

    pub fn load_text(&self, path: &Path) -> Result<String, FileLoadError> {
        self.load_source_file(path).map(|file| file.text)
    }

    pub fn load_source_file(&self, path: &Path) -> Result<LoadedSourceFile, FileLoadError> {
        let metadata =
            fs::metadata(path).map_err(|error| FileLoadError::Read(error.to_string()))?;
        if metadata.is_dir() {
            return Err(FileLoadError::Directory);
        }
        if !metadata.is_file() {
            return Err(FileLoadError::NotRegularFile);
        }
        if metadata.len() > self.max_bytes {
            return Err(FileLoadError::TooLarge {
                size: metadata.len(),
                max: self.max_bytes,
            });
        }

        reject_binary_sample(path)?;
        let bytes = fs::read(path).map_err(|error| FileLoadError::Read(error.to_string()))?;
        let text = String::from_utf8(bytes).map_err(|_| FileLoadError::InvalidUtf8)?;
        let line_count = text.lines().count().max(1);

        Ok(LoadedSourceFile {
            text,
            size_bytes: metadata.len(),
            line_count,
        })
    }
}

fn reject_binary_sample(path: &Path) -> Result<(), FileLoadError> {
    let mut file = fs::File::open(path).map_err(|error| FileLoadError::Read(error.to_string()))?;
    let mut buffer = [0_u8; BINARY_SAMPLE_BYTES];
    let read = file
        .read(&mut buffer)
        .map_err(|error| FileLoadError::Read(error.to_string()))?;

    if buffer[..read].contains(&0) {
        return Err(FileLoadError::Binary);
    }

    Ok(())
}
