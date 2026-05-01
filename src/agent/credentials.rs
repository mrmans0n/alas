use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use anyhow::{Context, anyhow};

use super::AgentProviderEnvVar;

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct CredentialStoreKey {
    pub provider_id: String,
    pub field: String,
}

impl CredentialStoreKey {
    pub fn new(provider_id: impl Into<String>, field: impl Into<String>) -> Self {
        Self {
            provider_id: provider_id.into(),
            field: field.into(),
        }
    }

    fn service(&self) -> String {
        format!("alas.agent.{}", self.provider_id)
    }

    fn username(&self) -> &str {
        &self.field
    }
}

pub trait CredentialStore: Send + Sync {
    fn read_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<Option<String>>;
    fn write_secret(&self, key: &CredentialStoreKey, value: &str) -> anyhow::Result<()>;
    fn delete_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<()>;
}

#[derive(Clone, Default)]
pub struct MemoryCredentialStore {
    secrets: Arc<Mutex<HashMap<CredentialStoreKey, String>>>,
}

impl CredentialStore for MemoryCredentialStore {
    fn read_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<Option<String>> {
        Ok(self
            .secrets
            .lock()
            .expect("credential lock")
            .get(key)
            .cloned())
    }

    fn write_secret(&self, key: &CredentialStoreKey, value: &str) -> anyhow::Result<()> {
        self.secrets
            .lock()
            .expect("credential lock")
            .insert(key.clone(), value.to_string());
        Ok(())
    }

    fn delete_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<()> {
        self.secrets.lock().expect("credential lock").remove(key);
        Ok(())
    }
}

#[derive(Clone, Debug, Default)]
pub struct OsCredentialStore;

pub fn resolve_secure_env_values(
    provider_id: &str,
    env: &[AgentProviderEnvVar],
    store: &dyn CredentialStore,
) -> anyhow::Result<Vec<(String, String)>> {
    env.iter()
        .map(|entry| {
            if let Some(value) = &entry.value {
                Ok((entry.name.clone(), value.clone()))
            } else if let Some(secure_ref) = &entry.secure_ref {
                let field = secure_ref
                    .strip_prefix(&format!("{provider_id}/"))
                    .unwrap_or(secure_ref);
                let key = CredentialStoreKey::new(provider_id, field);
                let value = store.read_secret(&key)?.ok_or_else(|| {
                    anyhow!(
                        "missing credential for provider '{}' env var '{}'",
                        provider_id,
                        entry.name
                    )
                })?;
                Ok((entry.name.clone(), value))
            } else {
                Ok((entry.name.clone(), String::new()))
            }
        })
        .collect()
}

impl CredentialStore for OsCredentialStore {
    fn read_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<Option<String>> {
        let entry = keyring::Entry::new(&key.service(), key.username())
            .context("failed to create keyring entry")?;
        match entry.get_password() {
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(error).context("failed to read secret from OS credential store"),
        }
    }

    fn write_secret(&self, key: &CredentialStoreKey, value: &str) -> anyhow::Result<()> {
        keyring::Entry::new(&key.service(), key.username())
            .context("failed to create keyring entry")?
            .set_password(value)
            .context("failed to write secret to OS credential store")
    }

    fn delete_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<()> {
        let entry = keyring::Entry::new(&key.service(), key.username())
            .context("failed to create keyring entry")?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error).context("failed to delete secret from OS credential store"),
        }
    }
}
