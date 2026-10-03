pub mod acp_broker;
pub mod acp_broker_process;
pub mod acp_broker_protocol;
pub mod remote_sessions;

use std::ffi::OsString;
use std::path::PathBuf;

/// Root for the helper's on-disk state (broker and process directories).
/// Alas sets `ALAS_HELPER_STATE_DIR` for an isolated profile so a second
/// instance's helper never shares brokers with the main one; otherwise, and
/// for any value that is not an absolute path, it is `$HOME/.alas`.
pub fn helper_state_dir() -> Option<PathBuf> {
    helper_state_dir_from(
        std::env::var_os("ALAS_HELPER_STATE_DIR"),
        std::env::var_os("HOME"),
    )
}

fn helper_state_dir_from(state_dir: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    if let Some(dir) = state_dir.map(PathBuf::from) {
        if dir.is_absolute() {
            return Some(dir);
        }
    }
    home.map(|home| PathBuf::from(home).join(".alas"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_state_dir_prefers_an_absolute_override_over_home() {
        let home = Some(OsString::from("/Users/me"));
        assert_eq!(
            helper_state_dir_from(Some("/tmp/alas-501-abcd".into()), home.clone()),
            Some(PathBuf::from("/tmp/alas-501-abcd"))
        );
        for ignored in [
            None,
            Some(OsString::from("")),
            Some(OsString::from("relative/dir")),
        ] {
            assert_eq!(
                helper_state_dir_from(ignored, home.clone()),
                Some(PathBuf::from("/Users/me/.alas"))
            );
        }
    }
}
