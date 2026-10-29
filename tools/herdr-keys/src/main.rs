//! herdr-keys: herdr maneuvers too compound for a plain keybinding, run by
//! `[[keys.command]]` shell bindings in ~/.config/herdr/config.toml.
//!
//!   nav <dir>             focus the pane in <dir>; past the tab's edge, go to
//!                         the previous/next tab (left/right) or sidebar
//!                         workspace (up/down), wrapping, landing on the pane
//!                         nearest the edge crossed
//!   new pane <dir>        split the focused pane, new pane on the <dir> side
//!   new tab left|right    new tab directly left/right of the current tab
//!   new workspace up|down new workspace directly above/below the current
//!                         sidebar row (or worktree group)
//!
//! Runs once per keypress, so it stays std + serde_json and talks to the
//! socket directly (the herdr CLI costs ~4-17ms per call; this ~0.3ms).

mod herdr;
mod layout;
mod sidebar;

use herdr::{str_field, Context, Herdr};
use layout::Rect;
use serde_json::{json, Value};
use std::time::Instant;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Dir {
    Left,
    Right,
    Up,
    Down,
}

impl Dir {
    fn parse(arg: Option<&str>) -> Option<Dir> {
        match arg? {
            "left" => Some(Dir::Left),
            "right" => Some(Dir::Right),
            "up" => Some(Dir::Up),
            "down" => Some(Dir::Down),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Dir::Left => "left",
            Dir::Right => "right",
            Dir::Up => "up",
            Dir::Down => "down",
        }
    }

    fn forward(self) -> bool {
        matches!(self, Dir::Right | Dir::Down)
    }
}

enum Command {
    Nav(Dir),
    NewPane(Dir),
    NewTab(Dir),
    NewWorkspace(Dir),
}

const USAGE: &str = "usage: herdr-keys nav <left|right|up|down>
       herdr-keys new pane <left|right|up|down>
       herdr-keys new tab <left|right>
       herdr-keys new workspace <up|down>";

fn main() {
    let start = Instant::now();
    raise_qos();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let command = match args.as_slice() {
        ["--version" | "-V"] => return println!("herdr-keys {}", env!("CARGO_PKG_VERSION")),
        ["--help" | "-h"] => return println!("{USAGE}"),
        ["nav", d] => Dir::parse(Some(d)).map(Command::Nav),
        ["new", "pane", d] => Dir::parse(Some(d)).map(Command::NewPane),
        ["new", "tab", d @ ("left" | "right")] => Dir::parse(Some(d)).map(Command::NewTab),
        ["new", "workspace", d @ ("up" | "down")] => Dir::parse(Some(d)).map(Command::NewWorkspace),
        _ => None,
    };
    let Some(command) = command else {
        eprintln!("{USAGE}");
        std::process::exit(2);
    };

    let mut herdr = Herdr::from_env(start);
    herdr.trace(&format!("start {}", args.join(" ")));
    let result = Context::resolve(&mut herdr).and_then(|ctx| match command {
        Command::Nav(dir) => nav(&mut herdr, &ctx, dir),
        Command::NewPane(dir) => new_pane(&mut herdr, &ctx, dir),
        Command::NewTab(dir) => new_tab(&mut herdr, &ctx, dir),
        Command::NewWorkspace(dir) => new_workspace(&mut herdr, &ctx, dir),
    });
    herdr.trace(&match &result {
        Ok(()) => "done".to_string(),
        Err(e) => format!("error: {e}"),
    });
    if let Err(e) = result {
        eprintln!("herdr-keys: {e}");
        std::process::exit(1);
    }
}

/// herdr spawns bindings from its background server, so they can inherit a
/// low QoS class (E-cores, coalesced timers). Ask for interactive priority.
#[cfg(target_os = "macos")]
fn raise_qos() {
    const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
    extern "C" {
        fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) -> i32;
    }
    unsafe {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

#[cfg(not(target_os = "macos"))]
fn raise_qos() {}

fn nav(herdr: &mut Herdr, ctx: &Context, dir: Dir) -> Result<(), String> {
    // Common case, one round trip: a neighbor exists inside the tab.
    let result = herdr.call(
        "pane.focus_direction",
        json!({ "direction": dir.as_str(), "pane_id": ctx.pane }),
    )?;
    let focus = &result["focus"];
    if focus["changed"].as_bool() == Some(true) || focus["reason"] != "no_neighbor" {
        return Ok(());
    }

    let source_layout = &focus["layout"];
    let source_tab = str_field(source_layout, "tab_id")?;
    let source_workspace = str_field(source_layout, "workspace_id")?;
    let source_pane = str_field(focus, "source_pane_id")?;
    let source_area = Rect::from_json(&source_layout["area"]).ok_or("layout missing area")?;
    let source_rect = panes(source_layout)
        .into_iter()
        .find(|(id, _)| *id == source_pane)
        .map(|(_, rect)| rect)
        .ok_or("source pane missing from layout")?;

    let snapshot = herdr.call("session.snapshot", json!({}))?["snapshot"].take();
    let target_tab = match dir {
        Dir::Left | Dir::Right => {
            let tabs: Vec<&str> = snapshot["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|t| t["workspace_id"] == source_workspace.as_str())
                .filter_map(|t| t["tab_id"].as_str())
                .collect();
            let at = tabs
                .iter()
                .position(|t| *t == source_tab)
                .ok_or("tab not found")?;
            tabs[step(at, tabs.len(), dir.forward())].to_string()
        }
        Dir::Up | Dir::Down => {
            let workspaces = sidebar::Workspace::list_from_json(&snapshot["workspaces"]);
            let collapsed = sidebar::collapsed_groups(herdr.socket());
            let order = sidebar::entries(&workspaces, &collapsed, &source_workspace);
            let at = order
                .iter()
                .position(|i| workspaces[*i].id == source_workspace)
                .unwrap_or(0);
            let target = &workspaces[order[step(at, order.len(), dir.forward())]].id;
            snapshot["workspaces"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|w| w["workspace_id"] == target.as_str())
                .and_then(|w| w["active_tab_id"].as_str())
                .ok_or("workspace has no active tab")?
                .to_string()
        }
    };

    let target_layout = snapshot["layouts"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|l| l["tab_id"] == target_tab.as_str())
        .ok_or("target tab layout missing")?;
    let target = if target_layout["zoomed"] == true {
        // Keep the zoomed pane zoomed rather than retargeting the zoom.
        str_field(target_layout, "focused_pane_id")?
    } else {
        let target_area = Rect::from_json(&target_layout["area"]).ok_or("layout missing area")?;
        let candidates = panes(target_layout);
        let remembered = target_layout["focused_pane_id"].as_str();
        layout::entry_pane(
            dir,
            source_area,
            source_rect,
            target_area,
            &candidates,
            remembered,
        )
        .ok_or("target tab has no panes")?
        .to_string()
    };
    if target == source_pane {
        return Ok(());
    }
    herdr.call("pane.focus", json!({ "pane_id": target }))?;
    Ok(())
}

fn new_pane(herdr: &mut Herdr, ctx: &Context, dir: Dir) -> Result<(), String> {
    // herdr only splits right/down; left/up split, then swap the halves.
    let split = if matches!(dir, Dir::Left | Dir::Right) {
        "right"
    } else {
        "down"
    };
    let created = herdr.call(
        "pane.split",
        json!({ "target_pane_id": ctx.pane, "direction": split, "cwd": ctx.cwd, "focus": true }),
    )?;
    if !dir.forward() {
        let new = str_field(&created["pane"], "pane_id")?;
        herdr.call(
            "pane.swap",
            json!({ "source_pane_id": new, "target_pane_id": ctx.pane }),
        )?;
    }
    Ok(())
}

fn new_tab(herdr: &mut Herdr, ctx: &Context, dir: Dir) -> Result<(), String> {
    // Create unfocused, place, then focus, so the tab never flashes at the end.
    let created = herdr.call(
        "tab.create",
        json!({ "workspace_id": ctx.workspace, "cwd": ctx.cwd, "focus": false }),
    )?;
    let new = str_field(&created["tab"], "tab_id")?;
    let tabs = herdr.call("tab.list", json!({ "workspace_id": ctx.workspace }))?;
    let tabs = tabs["tabs"].as_array().cloned().unwrap_or_default();
    let at = tabs
        .iter()
        .position(|t| t["tab_id"] == ctx.tab.as_str())
        .ok_or("current tab not found")?;
    let insert = if dir.forward() { at + 1 } else { at };
    if tabs.iter().position(|t| t["tab_id"] == new.as_str()) != Some(insert) {
        herdr.call("tab.move", json!({ "tab_id": new, "insert_index": insert }))?;
    }
    herdr.call("tab.focus", json!({ "tab_id": new }))?;
    Ok(())
}

fn new_workspace(herdr: &mut Herdr, ctx: &Context, dir: Dir) -> Result<(), String> {
    let created = herdr.call(
        "workspace.create",
        json!({ "cwd": ctx.cwd, "source_workspace_id": ctx.workspace, "focus": false }),
    )?;
    let new = str_field(&created["workspace"], "workspace_id")?;
    let listed = herdr.call("workspace.list", json!({}))?;
    let workspaces = sidebar::Workspace::list_from_json(&listed["workspaces"]);
    let at = workspaces
        .iter()
        .position(|w| w.id == ctx.workspace)
        .ok_or("current workspace not found")?;
    let anchor = sidebar::block_anchor(&workspaces, at);
    let insert = if dir.forward() { anchor + 1 } else { anchor };
    if workspaces.iter().position(|w| w.id == new) != Some(insert) {
        herdr.call(
            "workspace.move",
            json!({ "workspace_id": new, "insert_index": insert }),
        )?;
    }
    herdr.call("workspace.focus", json!({ "workspace_id": new }))?;
    Ok(())
}

fn panes(layout: &Value) -> Vec<(String, Rect)> {
    layout["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| {
            Some((
                p["pane_id"].as_str()?.to_string(),
                Rect::from_json(&p["rect"])?,
            ))
        })
        .collect()
}

/// Neighbor index with wraparound.
fn step(at: usize, len: usize, forward: bool) -> usize {
    if forward {
        (at + 1) % len
    } else {
        (at + len - 1) % len
    }
}
