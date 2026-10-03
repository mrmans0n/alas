use base64::Engine;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const STALE_AFTER: i64 = 60;
#[derive(Debug)]
pub struct RemoteSessionError {
    pub code: i64,
    pub message: String,
}
impl From<rusqlite::Error> for RemoteSessionError {
    fn from(error: rusqlite::Error) -> Self {
        Self {
            code: -32080,
            message: format!("Remote session storage failed: {error}"),
        }
    }
}
fn error(code: i64, message: &str) -> RemoteSessionError {
    RemoteSessionError {
        code,
        message: message.into(),
    }
}
fn lost() -> RemoteSessionError {
    error(-32081, "Remote session writer lease was lost")
}
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSessionFence {
    pub record_id: String,
    pub token: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Key {
    worktree_path: String,
    agent_id: String,
    remote_session_id: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Owner {
    server_id: String,
    instance_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Claim {
    key: Key,
    owner: Owner,
    proposed_proc_id: String,
    requested_token: String,
    previous_fence: Option<RemoteSessionFence>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Bind {
    fence: RemoteSessionFence,
    remote_session_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Heartbeat {
    fence: RemoteSessionFence,
    status: String,
}
#[derive(Deserialize)]
struct Fenced {
    fence: RemoteSessionFence,
}
#[derive(Deserialize)]
struct Observe {
    key: Key,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Lease {
    record_id: String,
    key: Key,
    proc_id: String,
    owner: Option<Owner>,
    status: String,
    is_fresh: bool,
    revision: i64,
}
struct Stored {
    lease: Lease,
    token: Option<String>,
}
fn decode<T: serde::de::DeserializeOwned>(params: Option<Value>) -> Result<T, RemoteSessionError> {
    serde_json::from_value(params.unwrap_or(json!({})))
        .map_err(|_| error(-32602, "Invalid remote session parameters"))
}
fn canonicalize(key: &mut Key) -> Result<(), RemoteSessionError> {
    key.worktree_path = std::fs::canonicalize(&key.worktree_path)
        .map_err(|_| error(-32602, "Remote worktree does not exist"))?
        .into_os_string()
        .into_string()
        .map_err(|_| error(-32602, "Invalid worktree path"))?;
    if key.agent_id.is_empty()
        || key
            .remote_session_id
            .as_ref()
            .is_some_and(|id| id.is_empty())
    {
        return Err(error(
            -32602,
            "Agent and remote session IDs must not be empty",
        ));
    }
    Ok(())
}
fn status_valid(status: &str) -> Result<(), RemoteSessionError> {
    if status != "busy" && status != "idle" {
        return Err(error(-32602, "Invalid session status"));
    }
    Ok(())
}
fn stored(row: &rusqlite::Row<'_>, now: i64) -> rusqlite::Result<Stored> {
    let server: Option<String> = row.get(5)?;
    let instance: Option<String> = row.get(6)?;
    let heartbeat: i64 = row.get(8)?;
    let owner = server.zip(instance).map(|(server_id, instance_id)| Owner {
        server_id,
        instance_id,
    });
    Ok(Stored {
        lease: Lease {
            record_id: row.get(0)?,
            key: Key {
                worktree_path: row.get(1)?,
                agent_id: row.get(2)?,
                remote_session_id: row.get(3)?,
            },
            proc_id: row.get(4)?,
            is_fresh: owner.is_some() && heartbeat > now - STALE_AFTER,
            owner,
            status: row.get(9)?,
            revision: row.get(10)?,
        },
        token: row.get(7)?,
    })
}
const COLUMNS: &str = "record_id,worktree_path,agent_id,remote_session_id,proc_id,owner_server_id,owner_instance_id,token,heartbeat_at,status,revision";
fn record(db: &Connection, id: &str, now: i64) -> Result<Option<Stored>, RemoteSessionError> {
    Ok(db
        .query_row(
            &format!("SELECT {COLUMNS} FROM remote_sessions WHERE record_id=?"),
            [id],
            |r| stored(r, now),
        )
        .optional()?)
}
fn check(
    db: &Connection,
    fence: &RemoteSessionFence,
    now: i64,
) -> Result<Stored, RemoteSessionError> {
    let current = record(db, &fence.record_id, now)?.ok_or_else(lost)?;
    if current.token.as_deref() != Some(fence.token.as_str()) || !current.lease.is_fresh {
        return Err(lost());
    }
    Ok(current)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Publish {
    fence: RemoteSessionFence,
    batch_id: String,
    entries: Vec<Entry>,
    status: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    kind: String,
    key: String,
    payload: Option<String>,
    revision: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadReplica {
    record_id: String,
    after_revision: i64,
    page_token: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CancelRead {
    page_token: String,
}
struct Snapshot {
    connection: Connection,
    record_id: String,
    after: i64,
    cutoff: i64,
    last: Option<(i64, String, String)>,
    touched: std::time::Instant,
}

pub struct RemoteSessionStore {
    connection: Connection,
    path: PathBuf,
    snapshots: HashMap<String, Snapshot>,
    next_snapshot: u64,
}
impl RemoteSessionStore {
    pub fn open(root: &Path) -> Result<Self, RemoteSessionError> {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        if std::fs::symlink_metadata(root).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(error(-32080, "Unsafe remote state directory"));
        }
        std::fs::create_dir_all(root)
            .map_err(|_| error(-32080, "Cannot create remote state directory"))?;
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| error(-32080, "Cannot protect remote state directory"))?;
        let path = root.join("remote_leases.sqlite");
        if std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(error(-32080, "Unsafe remote lease database"));
        }
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&path)
            .map_err(|_| error(-32080, "Cannot create remote lease database"))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| error(-32080, "Cannot protect remote lease database"))?;
        // WAL upgrades can return SQLITE_BUSY without invoking the busy handler.
        // A separate inode avoids conflicting with SQLite's own byte-range locks.
        // Never remove it: another helper may already be waiting on this inode.
        let lock_path = root.join("remote_leases.open.lock");
        if std::fs::symlink_metadata(&lock_path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(error(-32080, "Unsafe remote lease initialization lock"));
        }
        let initialization_lock = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(lock_path)
            .map_err(|_| error(-32080, "Cannot create remote lease initialization lock"))?;
        initialization_lock
            .lock()
            .map_err(|_| error(-32080, "Cannot lock remote lease database initialization"))?;
        let connection = Connection::open(&path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS remote_sessions (
                record_id TEXT PRIMARY KEY, worktree_path TEXT NOT NULL, agent_id TEXT NOT NULL,
                remote_session_id TEXT, proc_id TEXT NOT NULL UNIQUE, owner_server_id TEXT,
                owner_instance_id TEXT, token TEXT, heartbeat_at INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'idle', revision INTEGER NOT NULL DEFAULT 0,
                last_batch_id TEXT, last_batch_token TEXT);
            CREATE UNIQUE INDEX IF NOT EXISTS remote_session_identity ON remote_sessions(worktree_path,agent_id,remote_session_id) WHERE remote_session_id IS NOT NULL;
            CREATE TABLE IF NOT EXISTS remote_replica(
                record_id TEXT NOT NULL REFERENCES remote_sessions(record_id) ON DELETE CASCADE,
                kind TEXT NOT NULL, item_key TEXT NOT NULL, payload BLOB, revision INTEGER NOT NULL,
                PRIMARY KEY(record_id,kind,item_key));
            CREATE INDEX IF NOT EXISTS remote_replica_revision ON remote_replica(record_id,revision,kind,item_key);")?;
        Ok(Self {
            connection,
            path,
            snapshots: HashMap::new(),
            next_snapshot: 0,
        })
    }
    pub fn handle(
        &mut self,
        method: &str,
        params: Option<Value>,
        now: i64,
        retire_process: impl FnOnce(&str) -> Result<(), RemoteSessionError>,
    ) -> Result<Value, RemoteSessionError> {
        self.snapshots
            .retain(|_, snapshot| snapshot.touched.elapsed().as_secs() < 60);
        match method {
            "replica/publish" => self.publish(decode(params)?, now),
            "replica/read" => self.read_replica(decode(params)?, now),
            "replica/cancel" => {
                let p: CancelRead = decode(params)?;
                self.snapshots.remove(&p.page_token);
                Ok(json!({"ok":true}))
            }
            "lease/claim" | "lease/seize" => {
                self.claim(decode(params)?, method == "lease/seize", now, retire_process)
            }
            "lease/observe" => {
                let mut p: Observe = decode(params)?;
                canonicalize(&mut p.key)?;
                let current = self.connection.query_row(&format!("SELECT {COLUMNS} FROM remote_sessions WHERE worktree_path=? AND agent_id=? AND remote_session_id=?"),
                    params![p.key.worktree_path,p.key.agent_id,p.key.remote_session_id], |r| stored(r, now)).optional()?;
                Ok(json!({"lease":current.map(|c| c.lease)}))
            }
            "lease/bind" => {
                let p: Bind = decode(params)?;
                if p.remote_session_id.is_empty() {
                    return Err(error(-32602, "Empty remote session ID"));
                }
                let tx = self
                    .connection
                    .transaction_with_behavior(TransactionBehavior::Immediate)?;
                let current = check(&tx, &p.fence, now)?;
                if current
                    .lease
                    .key
                    .remote_session_id
                    .as_ref()
                    .is_some_and(|id| id != &p.remote_session_id)
                {
                    return Err(error(-32082, "Session already bound"));
                }
                let conflict: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM remote_sessions WHERE worktree_path=? AND agent_id=? AND remote_session_id=? AND record_id<>?)",
                    params![current.lease.key.worktree_path,current.lease.key.agent_id,p.remote_session_id,p.fence.record_id], |r| r.get(0))?;
                if conflict {
                    return Err(error(-32082, "Remote session already has a coordinator"));
                }
                tx.execute(
                    "UPDATE remote_sessions SET remote_session_id=? WHERE record_id=?",
                    params![p.remote_session_id, p.fence.record_id],
                )?;
                let bound = record(&tx, &p.fence.record_id, now)?.ok_or_else(lost)?;
                tx.commit()?;
                Ok(json!(bound.lease))
            }
            "lease/heartbeat" => {
                let p: Heartbeat = decode(params)?;
                status_valid(&p.status)?;
                let tx = self
                    .connection
                    .transaction_with_behavior(TransactionBehavior::Immediate)?;
                check(&tx, &p.fence, now)?;
                tx.execute(
                    "UPDATE remote_sessions SET heartbeat_at=?,status=? WHERE record_id=?",
                    params![now, p.status, p.fence.record_id],
                )?;
                let updated = record(&tx, &p.fence.record_id, now)?.ok_or_else(lost)?;
                tx.commit()?;
                Ok(json!(updated.lease))
            }
            "lease/release" => {
                let p: Fenced = decode(params)?;
                let tx = self
                    .connection
                    .transaction_with_behavior(TransactionBehavior::Immediate)?;
                // An expired but still matching owner may release its own record.
                let current = record(&tx, &p.fence.record_id, now)?.ok_or_else(lost)?;
                if current.token.as_deref() != Some(&p.fence.token) {
                    return Err(lost());
                }
                tx.execute("UPDATE remote_sessions SET owner_server_id=NULL,owner_instance_id=NULL,token=NULL,status='idle' WHERE record_id=?",[&p.fence.record_id])?;
                tx.commit()?;
                Ok(json!({"ok":true}))
            }
            "lease/delete" => {
                let p: Fenced = decode(params)?;
                let tx = self
                    .connection
                    .transaction_with_behavior(TransactionBehavior::Immediate)?;
                check(&tx, &p.fence, now)?;
                tx.execute(
                    "DELETE FROM remote_sessions WHERE record_id=?",
                    [&p.fence.record_id],
                )?;
                tx.commit()?;
                self.snapshots
                    .retain(|_, snapshot| snapshot.record_id != p.fence.record_id);
                Ok(json!({"ok":true}))
            }
            _ => Err(error(-32601, "Unknown remote session method")),
        }
    }
    fn claim(
        &mut self,
        mut p: Claim,
        seize: bool,
        now: i64,
        retire_process: impl FnOnce(&str) -> Result<(), RemoteSessionError>,
    ) -> Result<Value, RemoteSessionError> {
        canonicalize(&mut p.key)?;
        if p.owner.server_id.is_empty()
            || p.owner.instance_id.is_empty()
            || p.requested_token.is_empty()
            || p.proposed_proc_id.is_empty()
            || p.proposed_proc_id.len() > 128
            || !p
                .proposed_proc_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(error(-32602, "Invalid remote owner or process identity"));
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing = if p.key.remote_session_id.is_some() {
            tx.query_row(&format!("SELECT {COLUMNS} FROM remote_sessions WHERE worktree_path=? AND agent_id=? AND remote_session_id=?"), params![p.key.worktree_path,p.key.agent_id,p.key.remote_session_id], |r| stored(r,now)).optional()?
        } else {
            record(&tx, &p.proposed_proc_id, now)?
        };
        let id = if let Some(current) = existing {
            if current.lease.key.worktree_path != p.key.worktree_path
                || current.lease.key.agent_id != p.key.agent_id
            {
                return Err(error(
                    -32082,
                    "Process identity already belongs to another session",
                ));
            }
            let ours = current.lease.owner.as_ref() == Some(&p.owner)
                && current.token.as_deref() == Some(&p.requested_token);
            let replacing = current.lease.owner.as_ref() == Some(&p.owner)
                && p.previous_fence.as_ref().is_some_and(|f| {
                    f.record_id == current.lease.record_id
                        && current.token.as_ref() == Some(&f.token)
                });
            if ours && current.lease.is_fresh && !seize {
                tx.execute(
                    "UPDATE remote_sessions SET heartbeat_at=? WHERE record_id=?",
                    params![now, current.lease.record_id],
                )?;
                tx.commit()?;
                return Ok(
                    json!({"lease":current.lease,"fence":RemoteSessionFence{record_id:current.lease.record_id.clone(),token:p.requested_token}}),
                );
            }
            if current.lease.is_fresh && !ours && !replacing && !seize {
                tx.commit()?;
                return Ok(json!({"lease":current.lease,"fence":null}));
            }
            if seize && current.token.as_deref() == Some(&p.requested_token) && !ours {
                return Err(error(-32602, "Takeover requires a fresh token"));
            }
            if !seize
                && !current.lease.is_fresh
                && current
                    .lease
                    .owner
                    .as_ref()
                    .is_none_or(|owner| owner.server_id != p.owner.server_id)
            {
                // Neither an ownerless runtime nor a foreign owner's initialized protocol is reusable.
                // Retirement must succeed before the new fence is stored under this lock.
                retire_process(&current.lease.proc_id)?;
            }
            current.lease.record_id
        } else {
            tx.execute("INSERT INTO remote_sessions(record_id,worktree_path,agent_id,remote_session_id,proc_id) VALUES(?,?,?,?,?)",params![p.proposed_proc_id,p.key.worktree_path,p.key.agent_id,p.key.remote_session_id,p.proposed_proc_id])?;
            p.proposed_proc_id
        };
        tx.execute("UPDATE remote_sessions SET owner_server_id=?,owner_instance_id=?,token=?,heartbeat_at=?,status='idle' WHERE record_id=?", params![p.owner.server_id,p.owner.instance_id,p.requested_token,now,id])?;
        let current = record(&tx, &id, now)?.ok_or_else(lost)?;
        tx.commit()?;
        Ok(
            json!({"lease":current.lease,"fence":RemoteSessionFence{record_id:id,token:p.requested_token}}),
        )
    }
    fn publish(&mut self, p: Publish, now: i64) -> Result<Value, RemoteSessionError> {
        status_valid(&p.status)?;
        if p.batch_id.is_empty() {
            return Err(error(-32602, "Empty publication ID"));
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = check(&tx, &p.fence, now)?;
        let repeated: bool = tx.query_row(
            "SELECT last_batch_id=? AND last_batch_token=? FROM remote_sessions WHERE record_id=?",
            params![p.batch_id, p.fence.token, p.fence.record_id],
            |r| Ok(r.get::<_, Option<bool>>(0)?.unwrap_or(false)),
        )?;
        if repeated {
            return Ok(json!({"revision":current.lease.revision}));
        }
        let mut changed = Vec::new();
        for entry in p.entries {
            if ![
                "metadata",
                "message",
                "subagent",
                "queue",
                "fork",
                "relationship",
            ]
            .contains(&entry.kind.as_str())
                || entry.key.is_empty()
            {
                return Err(error(-32602, "Invalid replica entry"));
            }
            let payload = entry
                .payload
                .as_ref()
                .map(|p| base64::engine::general_purpose::STANDARD.decode(p))
                .transpose()
                .map_err(|_| error(-32602, "Invalid replica payload"))?;
            let previous: Option<Option<Vec<u8>>> = tx.query_row(
                "SELECT payload FROM remote_replica WHERE record_id=? AND kind=? AND item_key=?",
                params![p.fence.record_id,entry.kind,entry.key],|r|r.get(0)).optional()?;
            if previous.as_ref() != Some(&payload) {
                changed.push((entry.kind, entry.key, payload));
            }
        }
        let revision = current.lease.revision + i64::from(!changed.is_empty());
        for (kind, key, payload) in changed {
            tx.execute("INSERT INTO remote_replica(record_id,kind,item_key,payload,revision) VALUES(?,?,?,?,?)
                ON CONFLICT(record_id,kind,item_key) DO UPDATE SET payload=excluded.payload,revision=excluded.revision",
                params![p.fence.record_id,kind,key,payload,revision])?;
        }
        tx.execute("UPDATE remote_sessions SET revision=?,status=?,last_batch_id=?,last_batch_token=? WHERE record_id=?",
            params![revision,p.status,p.batch_id,p.fence.token,p.fence.record_id])?;
        tx.commit()?;
        Ok(json!({"revision":revision}))
    }
    fn read_replica(&mut self, p: ReadReplica, now: i64) -> Result<Value, RemoteSessionError> {
        if p.after_revision < 0 {
            return Err(error(-32602, "Invalid replica revision"));
        }
        let supplied_token = p.page_token.is_some();
        let token = p.page_token.unwrap_or_else(|| {
            self.next_snapshot += 1;
            format!("{}-{}", std::process::id(), self.next_snapshot)
        });
        let mut snapshot = if let Some(snapshot) = self.snapshots.remove(&token) {
            if snapshot.record_id != p.record_id || snapshot.after != p.after_revision {
                return Err(error(-32083, "Replica read expired"));
            }
            snapshot
        } else {
            // A supplied unknown token must not silently start a different snapshot.
            if supplied_token {
                return Err(error(-32083, "Replica read expired"));
            }
            let connection = Connection::open(&self.path)?;
            connection.busy_timeout(std::time::Duration::from_secs(5))?;
            connection.execute_batch("BEGIN")?;
            let cutoff = record(&connection, &p.record_id, now)?
                .ok_or_else(|| error(-32083, "Remote conversation no longer exists"))?
                .lease
                .revision;
            Snapshot {
                connection,
                record_id: p.record_id.clone(),
                after: p.after_revision,
                cutoff,
                last: None,
                touched: std::time::Instant::now(),
            }
        };
        // Deletion on another helper invalidates even a pinned read.
        if record(&self.connection, &p.record_id, now)?.is_none() {
            return Err(error(-32083, "Remote conversation was deleted"));
        }
        let last = snapshot.last.as_ref();
        let mut entries = Vec::new();
        let mut bytes = 0;
        let mut more = false;
        {
            let mut statement = snapshot.connection.prepare(
                "SELECT kind,item_key,payload,revision FROM remote_replica
                WHERE record_id=? AND revision>? AND (revision,kind,item_key)>(?,?,?)
                ORDER BY revision,kind,item_key LIMIT 257",
            )?;
            let mut rows = statement.query(params![
                snapshot.record_id,
                snapshot.after,
                last.map(|l| l.0).unwrap_or(0),
                last.map(|l| l.1.as_str()).unwrap_or(""),
                last.map(|l| l.2.as_str()).unwrap_or("")
            ])?;
            while let Some(row) = rows.next()? {
                let payload: Option<Vec<u8>> = row.get(2)?;
                let size = payload.as_ref().map(Vec::len).unwrap_or(0);
                if entries.len() == 256 || (!entries.is_empty() && bytes + size > 512 * 1024) {
                    more = true;
                    break;
                }
                bytes += size;
                entries.push(Entry {
                    kind: row.get(0)?,
                    key: row.get(1)?,
                    payload: payload.map(|p| base64::engine::general_purpose::STANDARD.encode(p)),
                    revision: row.get(3)?,
                });
            }
        }
        let cutoff = snapshot.cutoff;
        let next = if more {
            let entry = entries.last().expect("nonempty replica page");
            snapshot.last = Some((entry.revision, entry.kind.clone(), entry.key.clone()));
            snapshot.touched = std::time::Instant::now();
            self.snapshots.insert(token.clone(), snapshot);
            Some(token)
        } else {
            None
        };
        Ok(json!({"entries":entries,"cutoffRevision":cutoff,"nextPageToken":next}))
    }
    pub fn with_proc_fence<T, E: From<RemoteSessionError>>(
        &mut self,
        proc_id: &str,
        fence: Option<&RemoteSessionFence>,
        now: i64,
        operation: impl FnOnce() -> Result<T, E>,
    ) -> Result<T, E> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(RemoteSessionError::from)?;
        let associated: Option<String> = tx
            .query_row(
                "SELECT record_id FROM remote_sessions WHERE proc_id=?",
                [proc_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(RemoteSessionError::from)?;
        match (associated, fence) {
            (Some(id), Some(f)) if id == f.record_id => {
                check(&tx, f, now)?;
            }
            (None, None) => {}
            _ => return Err(lost().into()),
        }
        let result = operation()?;
        tx.commit().map_err(RemoteSessionError::from)?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn heartbeat_expiry_releases_authority_without_mac_pid_liveness() {
        let dir = std::env::temp_dir().join(format!(
            "lease-expiry-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let mut store = RemoteSessionStore::open(&dir).unwrap();
        let claim = |owner: &str| json!({"key":{"worktreePath":dir,"agentId":"test","remoteSessionId":"one"},"owner":{"serverId":owner,"instanceId":owner},"proposedProcId":format!("acp-{owner}"),"requestedToken":owner});
        let first = store
            .handle("lease/claim", Some(claim("a")), 100, |_| {
                panic!("a first claim must not retire a process")
            })
            .unwrap();
        assert!(!first["fence"].is_null());
        assert!(
            store
                .handle("lease/claim", Some(claim("b")), 159, |_| {
                    panic!("a denied fresh claim must not retire a process")
                })
                .unwrap()["fence"]
                .is_null()
        );
        let process_dir = dir.join("procs").join("acp-a");
        std::fs::create_dir_all(&process_dir).unwrap();
        assert!(
            !store
                .handle("lease/claim", Some(claim("b")), 160, |proc_id| {
                    std::fs::remove_dir_all(dir.join("procs").join(proc_id)).map_err(|failure| {
                        error(-32050, &format!("fixture retirement failed: {failure}"))
                    })
                })
                .unwrap()["fence"]
                .is_null()
        );
        assert!(!process_dir.exists());
        assert_eq!(
            store
                .handle(
                    "lease/heartbeat",
                    Some(json!({"fence":first["fence"],"status":"busy"})),
                    160,
                    |_| panic!("heartbeat must not retire a process"),
                )
                .unwrap_err()
                .code,
            -32081
        );
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
