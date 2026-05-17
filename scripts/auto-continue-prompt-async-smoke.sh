#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/context-governor-auto-prompt.XXXXXX)"
cleanup() {
  local status=$?
  if [ "$status" -eq 0 ]; then
    rm -rf "$FIXTURE"
  else
    printf 'auto-continue prompt-async smoke failed; fixture left at %s\n' "$FIXTURE" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.opencode"
cat > "$FIXTURE/.opencode/opencode.json" <<JSON
{"plugin":[["$REPO_ROOT/src/plugin.js",{"autoContinue":"prompt-async","log":true}]]}
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
        return { data: { session: { id: `ses_child_prompt_${calls.create.length}` } } }
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
  autoContinue: "prompt-async",
  autoContinueMaxChain: 1,
  handoffThreshold: 0,
  warnThreshold: 0,
  informThreshold: 0,
  reserveOutputTokens: 0,
})

await hooks["experimental.chat.system.transform"](
  { sessionID: "ses_parent_prompt", agent: "general", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
  { system: [] },
)
await hooks.event({ event: { type: "message.part.updated", properties: { sessionID: "ses_parent_prompt", part: { type: "text", text: "CONTEXT_GOVERNOR_HANDOFF\nContinue safely." } } } })
await hooks.event({ event: { type: "message.updated", properties: { sessionID: "ses_parent_prompt", message: { role: "assistant", status: "completed", parts: [] } } } })

if (calls.create.length !== 1) throw new Error(`expected one child create, got ${calls.create.length}`)
if (calls.promptAsync.length !== 1) throw new Error(`expected one promptAsync, got ${calls.promptAsync.length}`)
if (calls.promptAsync[0].body.noReply !== false) throw new Error("prompt-async must use noReply=false")
if (calls.promptAsync[0].body.agent !== "general") throw new Error("promptAsync should preserve agent when known")

await hooks["experimental.chat.system.transform"](
  { sessionID: "ses_child_prompt_1", agent: "general", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
  { system: [] },
)
await hooks.event({ event: { type: "message.part.updated", properties: { sessionID: "ses_child_prompt_1", part: { type: "text", text: "CONTEXT_GOVERNOR_HANDOFF\nNested handoff." } } } })
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_child_prompt_1" } } })
if (calls.create.length !== 1) throw new Error("max chain should block nested continuation")

const statePath = path.join(fixture, ".context-governor-handoffs.jsonl")
const state = fs.readFileSync(statePath, "utf8")
if (!state.includes('"noReply":false')) throw new Error("state file missing noReply=false record")
console.log("auto-continue prompt-async smoke validation passed")
NODE
