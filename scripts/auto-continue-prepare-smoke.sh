#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/context-governor-auto-prepare.XXXXXX)"
cleanup() {
  local status=$?
  if [ "$status" -eq 0 ]; then
    rm -rf "$FIXTURE"
  else
    printf 'auto-continue prepare smoke failed; fixture left at %s\n' "$FIXTURE" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.opencode"
cat > "$FIXTURE/.opencode/opencode.json" <<JSON
{"plugin":[["$REPO_ROOT/src/plugin.js",{"autoContinue":"prepare-only","log":true}]]}
JSON

FIXTURE="$FIXTURE" REPO_ROOT="$REPO_ROOT" node --input-type=module <<'NODE'
import fs from "node:fs"
import path from "node:path"
const { default: plugin } = await import(`file://${process.env.REPO_ROOT}/src/plugin.js`)

const fixture = process.env.FIXTURE
const calls = { create: [], promptAsync: [], select: [] }
const ctx = {
  directory: fixture,
  client: {
    session: {
      async create(args) {
        calls.create.push(args)
        return { id: "ses_child_prepare" }
      },
      async promptAsync(args) {
        calls.promptAsync.push(args)
        return { ok: true }
      },
    },
    _client: {
      async post(args) {
        calls.select.push(args)
        return { data: true }
      },
    },
  },
}

const hooks = await plugin.server(ctx, {
  log: true,
  autoContinue: "prepare-only",
  handoffThreshold: 0,
  warnThreshold: 0,
  informThreshold: 0,
  reserveOutputTokens: 0,
})

await hooks["experimental.chat.system.transform"](
  { sessionID: "ses_parent_prepare", agent: "general", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
  { system: [] },
)
await hooks.event({ event: { type: "message.part.updated", properties: { sessionID: "ses_parent_prepare", part: { type: "text", text: "CONTEXT_GOVERNOR_HANDOFF\nGoal and next steps." } } } })
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_parent_prepare" } } })
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_parent_prepare" } } })

if (calls.create.length !== 1) throw new Error(`expected one child create, got ${calls.create.length}`)
if (calls.create[0].body.parentID !== "ses_parent_prepare") throw new Error("child parentID mismatch")
if (calls.promptAsync.length !== 1) throw new Error(`expected one promptAsync, got ${calls.promptAsync.length}`)
if (calls.promptAsync[0].body.noReply !== true) throw new Error("prepare-only must use noReply=true")
if (!calls.promptAsync[0].body.parts[0].text.includes("CONTEXT_GOVERNOR_HANDOFF")) throw new Error("prompt missing handoff marker")
if (calls.select.length !== 2) throw new Error(`expected two TUI select attempts, got ${calls.select.length}`)

const statePath = path.join(fixture, ".context-governor-handoffs.jsonl")
const state = fs.readFileSync(statePath, "utf8")
if (!state.includes('"status":"created"')) throw new Error("state file missing created record")
console.log("auto-continue prepare smoke validation passed")
NODE
