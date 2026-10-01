//! The board stored by the previous version of the plugin, read only to migrate it to tickets.

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum Column {
    Backlog,
    Running,
    NeedsYou,
    Review,
    Done,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Card {
    pub id: u64,
    pub title: String,
    pub prompt: String,
    pub column: Column,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub following: bool,
    #[serde(default)]
    pub seen: bool,
    #[serde(default)]
    pub agent_state: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Board {
    pub cards: Vec<Card>,
    pub next_id: u64,
}
