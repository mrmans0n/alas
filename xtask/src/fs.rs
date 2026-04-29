use std::path::Path;

use anyhow::{Context, Result};

pub fn reset_dir(path: &Path) -> Result<()> {
    if path.exists() {
        std::fs::remove_dir_all(path)
            .with_context(|| format!("removing directory {}", path.display()))?;
    }
    std::fs::create_dir_all(path)
        .with_context(|| format!("creating directory {}", path.display()))?;
    Ok(())
}

pub fn copy_file(from: &Path, to: &Path) -> Result<()> {
    if let Some(parent) = to.parent().filter(|path| !path.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating parent directory {}", parent.display()))?;
    }
    std::fs::copy(from, to)
        .with_context(|| format!("copying file from {} to {}", from.display(), to.display()))?;
    Ok(())
}

#[cfg(unix)]
pub fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = std::fs::metadata(path)
        .with_context(|| format!("reading metadata for {}", path.display()))?
        .permissions();
    permissions.set_mode(permissions.mode() | 0o755);
    std::fs::set_permissions(path, permissions)
        .with_context(|| format!("setting executable permissions on {}", path.display()))?;
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

    #[cfg(unix)]
    #[test]
    fn make_executable_sets_executable_bits() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join("run.sh");
        fs::write(&script, "#!/bin/sh\n").unwrap();

        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o600);
        fs::set_permissions(&script, permissions).unwrap();

        make_executable(&script).unwrap();

        let mode = fs::metadata(script).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o755);
    }
}
