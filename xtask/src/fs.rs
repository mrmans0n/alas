use std::path::Path;

use anyhow::Result;

pub fn reset_dir(path: &Path) -> Result<()> {
    if path.exists() {
        std::fs::remove_dir_all(path)?;
    }
    std::fs::create_dir_all(path)?;
    Ok(())
}

pub fn copy_file(from: &Path, to: &Path) -> Result<()> {
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(from, to)?;
    Ok(())
}

#[cfg(unix)]
pub fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = std::fs::metadata(path)?.permissions();
    permissions.set_mode(permissions.mode() | 0o755);
    std::fs::set_permissions(path, permissions)?;
    Ok(())
}

#[cfg(not(unix))]
pub fn make_executable(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn reset_dir_removes_existing_contents() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().join("staging");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("old.txt"), "old").unwrap();

        reset_dir(&dir).unwrap();

        assert!(dir.is_dir());
        assert!(!dir.join("old.txt").exists());
    }

    #[test]
    fn copy_file_creates_parent_dirs() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.txt");
        let dest = temp.path().join("nested/target.txt");
        fs::write(&source, "hello").unwrap();

        copy_file(&source, &dest).unwrap();

        assert_eq!(fs::read_to_string(dest).unwrap(), "hello");
    }
}
