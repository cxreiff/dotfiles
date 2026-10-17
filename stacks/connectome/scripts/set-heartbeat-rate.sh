#!/usr/bin/env bash
# Set the heartbeat wake rate_limit in every live session gate.json (hot-
# reloaded) — the recipe only seeds new sessions. Keep recipes/agent.json in
# sync by hand. Exit: 0 ok; 2 usage; 3 no session found.
set -euo pipefail
[[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: set-heartbeat-rate.sh <tokens> <refillIntervalMs>" >&2; exit 2; }
docker --context colima-agents exec -e T="$1" -e R="$2" connectome /opt/node/bin/node -e '
  const fs = require("fs"), path = require("path");
  const root = "/agent/state/data/sessions";
  const files = fs.existsSync(root) ? fs.readdirSync(root).map(s => path.join(root, s, "config", "gate.json")).filter(f => fs.existsSync(f)) : [];
  if (!files.length) { console.error("no session gate.json found"); process.exit(3); }
  for (const f of files) {
    const g = JSON.parse(fs.readFileSync(f, "utf8"));
    const p = (g.policies || []).find(p => p.name === "heartbeat-rate-limit");
    if (!p) { console.error(`${f}: no heartbeat-rate-limit policy`); process.exit(3); }
    p.behavior = { rate_limit: { tokens: Number(process.env.T), refillIntervalMs: Number(process.env.R) } };
    fs.writeFileSync(f + ".tmp", JSON.stringify(g, null, 2) + "\n"); fs.renameSync(f + ".tmp", f);
    console.log(`${f}: heartbeat-rate-limit = ${process.env.T} tokens / ${process.env.R} ms`);
  }'
