//! Minimal client for the herdr socket API (newline-delimited JSON, one
//! request per connection) plus the context herdr hands custom commands.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const READ_TIMEOUT: Duration = Duration::from_secs(3);

pub struct Herdr {
    socket: PathBuf,
    trace: Option<std::fs::File>,
    start: Instant,
}

impl Herdr {
    pub fn from_env(start: Instant) -> Self {
        let trace = std::env::var_os("HERDR_KEYS_TRACE").and_then(|path| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .ok()
        });
        Herdr {
            socket: socket_path(),
            trace,
            start,
        }
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        // Serialize before connecting. The server reads the request line
        // non-blocking right after accept and, if nothing has arrived yet,
        // sleeps 100ms before retrying (~250ms observed on macOS). Writing the
        // whole line in one write directly after connect avoids that stall.
        let mut line = serde_json::to_vec(&json!({
            "id": "herdr-keys",
            "method": method,
            "params": params,
        }))
        .map_err(|e| e.to_string())?;
        line.push(b'\n');

        let sent = Instant::now();
        let mut stream = UnixStream::connect(&self.socket)
            .map_err(|e| format!("connect {}: {e}", self.socket.display()))?;
        stream
            .write_all(&line)
            .map_err(|e| format!("{method}: {e}"))?;
        stream
            .set_read_timeout(Some(READ_TIMEOUT))
            .map_err(|e| e.to_string())?;
        let mut response = Vec::with_capacity(4096);
        BufReader::new(&stream)
            .read_until(b'\n', &mut response)
            .map_err(|e| format!("{method}: {e}"))?;
        self.trace(&format!(
            "{method} {:.2}ms",
            sent.elapsed().as_secs_f64() * 1e3
        ));

        let mut value: Value = serde_json::from_slice(&response)
            .map_err(|e| format!("{method}: bad response: {e}"))?;
        if let Some(error) = value.get("error") {
            return Err(format!("{method}: {error}"));
        }
        Ok(value["result"].take())
    }

    pub fn trace(&mut self, message: &str) {
        if let Some(file) = self.trace.as_mut() {
            let at = self.start.elapsed().as_secs_f64() * 1e3;
            let _ = writeln!(file, "[{at:7.2}ms] {message}");
        }
    }
}

/// Same resolution order as herdr: HERDR_SOCKET_PATH, then HERDR_SESSION,
/// then the default session.
fn socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("HERDR_SOCKET_PATH") {
        return PathBuf::from(path);
    }
    let config = config_dir();
    match std::env::var("HERDR_SESSION") {
        Ok(name) if !name.is_empty() && name != "default" => {
            config.join("sessions").join(name).join("herdr.sock")
        }
        _ => config.join("herdr.sock"),
    }
}

fn config_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME") {
        return PathBuf::from(dir).join("herdr");
    }
    home().join(".config/herdr")
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// What herdr exports to custom commands: the pressing client's view at the
/// moment of the keypress.
pub struct Context {
    pub workspace: String,
    pub tab: String,
    pub pane: String,
    pub cwd: Option<String>,
}

impl Context {
    pub fn resolve(herdr: &mut Herdr) -> Result<Self, String> {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
        let cwd = var("HERDR_ACTIVE_PANE_CWD");
        if let (Some(workspace), Some(tab), Some(pane)) = (
            var("HERDR_ACTIVE_WORKSPACE_ID"),
            var("HERDR_ACTIVE_TAB_ID"),
            var("HERDR_ACTIVE_PANE_ID"),
        ) {
            return Ok(Context {
                workspace,
                tab,
                pane,
                cwd,
            });
        }
        // Run by hand: fall back to the server's focused pane.
        let current = herdr.call("pane.current", json!({}))?;
        let pane = &current["pane"];
        Ok(Context {
            workspace: str_field(pane, "workspace_id")?,
            tab: str_field(pane, "tab_id")?,
            pane: str_field(pane, "pane_id")?,
            cwd: cwd.or_else(|| pane["cwd"].as_str().map(String::from)),
        })
    }
}

pub fn str_field(value: &Value, key: &str) -> Result<String, String> {
    value[key]
        .as_str()
        .map(String::from)
        .ok_or_else(|| format!("response missing {key}"))
}
