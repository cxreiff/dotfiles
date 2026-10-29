#!/usr/bin/env bash
# Build herdr-keys (release) and install it to ~/.local/bin, where
# ~/.config/herdr/config.toml's [[keys.command]] bindings call it.
set -euo pipefail

crate="$(cd "$(dirname "$0")/.." && pwd)"
dest="${HERDR_KEYS_INSTALL_DIR:-$HOME/.local/bin}"

cargo build --release --locked --manifest-path "$crate/Cargo.toml"
bin="$crate/target/release/herdr-keys"

# Install by rename, never by overwriting in place: on Apple Silicon the
# kernel caches a binary's code signature per vnode, and rewriting a running
# or recently run executable's bytes gets later launches SIGKILLed
# ("Killed: 9"). A fresh inode moved over the old path avoids that.
mkdir -p "$dest"
tmp="$(mktemp "$dest/.herdr-keys.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$bin" "$tmp"
chmod 0755 "$tmp"
# Locally built binaries carry no quarantine xattr, but strip any so
# Gatekeeper never assesses (and delays) the first keypress.
xattr -c "$tmp" 2>/dev/null || true
codesign --verify "$tmp"
mv -f "$tmp" "$dest/herdr-keys"
trap - EXIT

# First exec of a new binary pays the one-time signature validation; take it
# here instead of on the first keypress.
"$dest/herdr-keys" --version
