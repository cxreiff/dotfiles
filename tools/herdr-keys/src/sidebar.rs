//! Workspace order as herdr's sidebar shows it, which is not `workspace.list`
//! order: a worktree group (two or more workspaces sharing a repo key, one of
//! them the primary checkout) renders as one block at its first member's list
//! position, primary first, and a collapsed group shows only its primary plus
//! the focused child. Ported from herdr v0.9.0 `workspace_entries` in
//! src/client/shell/sidebar.rs, which also drives its next/previous_workspace.

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub struct Workspace {
    pub id: String,
    /// (repo_key, is_linked_worktree)
    pub worktree: Option<(String, bool)>,
}

impl Workspace {
    pub fn list_from_json(workspaces: &Value) -> Vec<Workspace> {
        workspaces
            .as_array()
            .map(|all| {
                all.iter()
                    .map(|w| Workspace {
                        id: w["workspace_id"].as_str().unwrap_or_default().to_string(),
                        worktree: w["worktree"]["repo_key"].as_str().map(|key| {
                            let linked = w["worktree"]["is_linked_worktree"].as_bool();
                            (key.to_string(), linked.unwrap_or(false))
                        }),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// Repo keys of groups with a sidebar block, and each group's members in list order.
fn groups(workspaces: &[Workspace]) -> (HashSet<&str>, HashMap<&str, Vec<usize>>) {
    let mut members = HashMap::<&str, Vec<usize>>::new();
    for (index, workspace) in workspaces.iter().enumerate() {
        if let Some((key, _)) = &workspace.worktree {
            members.entry(key.as_str()).or_default().push(index);
        }
    }
    let grouped = members
        .iter()
        .filter(|(_, indices)| {
            indices.len() >= 2
                && indices.iter().any(|i| {
                    workspaces[*i]
                        .worktree
                        .as_ref()
                        .is_some_and(|(_, linked)| !linked)
                })
        })
        .map(|(key, _)| *key)
        .collect();
    (grouped, members)
}

/// List indices in sidebar order, skipping children hidden by collapsed groups.
/// `focused` is the workspace the pressing client is viewing.
pub fn entries(workspaces: &[Workspace], collapsed: &HashSet<String>, focused: &str) -> Vec<usize> {
    let (grouped, members) = groups(workspaces);
    let mut emitted = HashSet::<&str>::new();
    let mut entries = Vec::new();
    for (index, workspace) in workspaces.iter().enumerate() {
        let Some((key, _)) = workspace
            .worktree
            .as_ref()
            .filter(|(key, _)| grouped.contains(key.as_str()))
        else {
            entries.push(index);
            continue;
        };
        if !emitted.insert(key.as_str()) {
            continue;
        }
        let group = &members[key.as_str()];
        let parent = group
            .iter()
            .copied()
            .find(|m| {
                workspaces[*m]
                    .worktree
                    .as_ref()
                    .is_some_and(|(_, linked)| !linked)
            })
            .unwrap_or(index);
        entries.push(parent);
        let children = group.iter().copied().filter(|m| *m != parent);
        if collapsed.contains(key) {
            entries.extend(children.filter(|m| workspaces[*m].id == focused).take(1));
        } else {
            entries.extend(children);
        }
    }
    entries
}

/// List index where the sidebar block containing `index` starts: its own
/// index, or for a group member the index of the group's first member.
/// Inserting a plain workspace at `anchor` places it directly above the
/// block, at `anchor + 1` directly below it.
pub fn block_anchor(workspaces: &[Workspace], index: usize) -> usize {
    let (grouped, members) = groups(workspaces);
    workspaces[index]
        .worktree
        .as_ref()
        .filter(|(key, _)| grouped.contains(key.as_str()))
        .map_or(index, |(key, _)| members[key.as_str()][0])
}

/// Collapsed group keys from the local client's persisted preferences, at
/// `<state>/client-shell/local-<fnv1a64(client socket)>.json`, the client
/// socket being the API socket's sibling `<stem>-client.sock`.
pub fn collapsed_groups(api_socket: &Path) -> HashSet<String> {
    let path = preferences_path(api_socket);
    let Ok(content) = std::fs::read(&path) else {
        return HashSet::new();
    };
    serde_json::from_slice::<Value>(&content)
        .ok()
        .and_then(|prefs| {
            prefs["collapsed_groups"].as_array().map(|keys| {
                keys.iter()
                    .filter_map(|key| key.as_str().map(String::from))
                    .collect()
            })
        })
        .unwrap_or_default()
}

fn preferences_path(api_socket: &Path) -> PathBuf {
    let stem = api_socket
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("herdr");
    let client_socket = api_socket
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join(format!("{stem}-client.sock"));
    let mut hash = 0xcbf29ce484222325u64;
    for byte in client_socket.to_string_lossy().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    let state = match std::env::var_os("XDG_STATE_HOME") {
        Some(dir) => PathBuf::from(dir).join("herdr"),
        None => crate::herdr::home().join(".local/state/herdr"),
    };
    state
        .join("client-shell")
        .join(format!("local-{hash:016x}.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws(id: &str, worktree: Option<(&str, bool)>) -> Workspace {
        Workspace {
            id: id.into(),
            worktree: worktree.map(|(k, l)| (k.into(), l)),
        }
    }

    // List order: a, child1(repo), b, primary(repo), child2(repo), c
    fn mixed() -> Vec<Workspace> {
        vec![
            ws("a", None),
            ws("child1", Some(("repo", true))),
            ws("b", None),
            ws("primary", Some(("repo", false))),
            ws("child2", Some(("repo", true))),
            ws("c", None),
        ]
    }

    fn ids(list: &[Workspace], entries: &[usize]) -> Vec<String> {
        entries.iter().map(|i| list[*i].id.clone()).collect()
    }

    #[test]
    fn group_renders_at_first_member_primary_first() {
        let list = mixed();
        let order = entries(&list, &HashSet::new(), "a");
        assert_eq!(
            ids(&list, &order),
            ["a", "primary", "child1", "child2", "b", "c"]
        );
    }

    #[test]
    fn collapsed_group_shows_only_the_focused_child() {
        let list = mixed();
        let collapsed = HashSet::from(["repo".to_string()]);
        assert_eq!(
            ids(&list, &entries(&list, &collapsed, "a")),
            ["a", "primary", "b", "c"]
        );
        assert_eq!(
            ids(&list, &entries(&list, &collapsed, "child2")),
            ["a", "primary", "child2", "b", "c"]
        );
    }

    #[test]
    fn groups_need_two_members_and_a_primary() {
        let list = vec![
            ws("lone", Some(("x", false))),
            ws("linked1", Some(("y", true))),
            ws("a", None),
            ws("linked2", Some(("y", true))),
        ];
        assert_eq!(
            ids(&list, &entries(&list, &HashSet::new(), "a")),
            ["lone", "linked1", "a", "linked2"]
        );
    }

    #[test]
    fn anchor_is_the_block_start() {
        let list = mixed();
        assert_eq!(block_anchor(&list, 0), 0);
        assert_eq!(block_anchor(&list, 2), 2);
        for member in [1, 3, 4] {
            assert_eq!(block_anchor(&list, member), 1);
        }
    }

    #[test]
    fn inserting_at_anchor_lands_beside_the_block() {
        // New plain workspace below the group (anchor + 1), then above b (anchor).
        let mut list = mixed();
        list.insert(block_anchor(&list, 4) + 1, ws("new", None));
        let order = ids(&list, &entries(&list, &HashSet::new(), "new"));
        assert_eq!(order, ["a", "primary", "child1", "child2", "new", "b", "c"]);

        let mut list = mixed();
        list.insert(block_anchor(&list, 2), ws("new", None));
        let order = ids(&list, &entries(&list, &HashSet::new(), "new"));
        assert_eq!(order, ["a", "primary", "child1", "child2", "new", "b", "c"]);
    }

    #[test]
    fn preferences_path_matches_herdr() {
        std::env::set_var("XDG_STATE_HOME", "/state");
        let path = preferences_path(Path::new("/run/herdr/herdr.sock"));
        let mut hash = 0xcbf29ce484222325u64;
        for byte in b"/run/herdr/herdr-client.sock" {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        assert_eq!(
            path,
            PathBuf::from(format!("/state/herdr/client-shell/local-{hash:016x}.json"))
        );
    }
}
