use std::{fs, path::Path};

pub const MAX_TEXT_FILE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FileLoadError {
    #[error("path is a directory")]
    Directory,
    #[error("file is too large ({size} bytes, max {max} bytes)")]
    TooLarge { size: u64, max: u64 },
    #[error("file is not valid UTF-8")]
    InvalidUtf8,
    #[error("failed to read file: {0}")]
    Read(String),
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
        let metadata =
            fs::metadata(path).map_err(|error| FileLoadError::Read(error.to_string()))?;
        if metadata.is_dir() {
            return Err(FileLoadError::Directory);
        }
        if metadata.len() > self.max_bytes {
            return Err(FileLoadError::TooLarge {
                size: metadata.len(),
                max: self.max_bytes,
            });
        }

        let bytes = fs::read(path).map_err(|error| FileLoadError::Read(error.to_string()))?;
        String::from_utf8(bytes).map_err(|_| FileLoadError::InvalidUtf8)
    }
}
