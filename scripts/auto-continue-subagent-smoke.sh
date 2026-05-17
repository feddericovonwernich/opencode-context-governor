#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/context-governor-auto-subagent.XXXXXX)"
cleanup() {
  local status=$?
  if [ "$status" -eq 0 ]; then
    rm -rf "$FIXTURE"
  else
    printf 'auto-continue subagent smoke failed; fixture left at %s\n' "$FIXTURE" >&2
  fi
}
trap cleanup EXIT

FIXTURE="$FIXTURE" REPO_ROOT="$REPO_ROOT" node --input-type=module <<'NODE'
import fs from "node:fs"
import path from "node:path"
const { default: plugin } = await import(`file://${process.env.REPO_ROOT}/src/plugin.js`)

const fixture = process.env.FIXTURE

function makeCtx(childPrefix) {
  const calls = { create: [], promptAsync: [], select: [] }
  const ctx = {
    directory: fixture,
    client: {
      session: {
        async create(args) {
          calls.create.push(args)
          return { id: `${childPrefix}_${calls.create.length}` }
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
  return { ctx, calls }
}

async function triggerSubagentHandoff(hooks, sessionID, parentID = "ses_parent") {
  await hooks["experimental.chat.system.transform"](
    {
      sessionID,
      parentSessionID: parentID,
      agent: "general",
      model: { id: "test", providerID: "test", limit: { context: 1000 } },
    },
    { system: [] },
  )
  await hooks.event({
    event: {
      type: "message.part.updated",
      properties: {
        sessionID,
        parentSessionID: parentID,
        part: { type: "text", text: "CONTEXT_GOVERNOR_HANDOFF\nSubagent handoff." },
      },
    },
  })
  await hooks.event({ event: { type: "session.idle", properties: { sessionID, parentSessionID: parentID } } })
}

async function runCase(name, options) {
  const { ctx, calls } = makeCtx(`ses_child_${name}`)
  const hooks = await plugin.server(ctx, {
    log: true,
    autoContinue: "prompt-async",
    handoffThreshold: 0,
    warnThreshold: 0,
    informThreshold: 0,
    reserveOutputTokens: 0,
    ...options,
  })
  await hooks["tool.execute.after"](
    { sessionID: `ses_parent_${name}`, tool: "task" },
    { output: "task started", metadata: { parentSessionId: `ses_parent_${name}`, sessionId: `ses_subagent_${name}` } },
  )
  await triggerSubagentHandoff(hooks, `ses_subagent_${name}`, `ses_parent_${name}`)
  return calls
}

const defaultCalls = await runCase("default", {})
if (defaultCalls.create.length !== 1) throw new Error(`default: expected one child create, got ${defaultCalls.create.length}`)
if (defaultCalls.promptAsync.length !== 1) throw new Error(`default: expected one promptAsync, got ${defaultCalls.promptAsync.length}`)
if (defaultCalls.promptAsync[0].body.noReply !== true) throw new Error("default subagent policy must use prepare-only noReply=true")
if (defaultCalls.select.length !== 0) throw new Error(`default subagent policy must not select TUI, got ${defaultCalls.select.length}`)

const offCalls = await runCase("off", { autoContinueSubagents: "off" })
if (offCalls.create.length !== 0) throw new Error(`off: expected no child create, got ${offCalls.create.length}`)
if (offCalls.promptAsync.length !== 0) throw new Error(`off: expected no promptAsync, got ${offCalls.promptAsync.length}`)

const inheritCalls = await runCase("inherit", { autoContinueSubagents: "inherit" })
if (inheritCalls.create.length !== 1) throw new Error(`inherit: expected one child create, got ${inheritCalls.create.length}`)
if (inheritCalls.promptAsync.length !== 1) throw new Error(`inherit: expected one promptAsync, got ${inheritCalls.promptAsync.length}`)
if (inheritCalls.promptAsync[0].body.noReply !== false) throw new Error("inherit subagent policy must preserve prompt-async noReply=false")

const { ctx: duplicateCtx, calls: duplicateCalls } = makeCtx("ses_child_duplicate")
const duplicateHooks = await plugin.server(duplicateCtx, {
  log: true,
  autoContinue: "prompt-async",
  handoffThreshold: 0,
  warnThreshold: 0,
  informThreshold: 0,
  reserveOutputTokens: 0,
})
await duplicateHooks["tool.execute.after"](
  { sessionID: "ses_parent_duplicate", tool: "task" },
  { output: "task started", metadata: { parentSessionId: "ses_parent_duplicate", sessionId: "ses_subagent_duplicate" } },
)
await triggerSubagentHandoff(duplicateHooks, "ses_subagent_duplicate", "ses_parent_duplicate")
await duplicateHooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_subagent_duplicate", parentSessionID: "ses_parent_duplicate" } } })
await duplicateHooks.event({ event: { type: "message.updated", properties: { sessionID: "ses_subagent_duplicate", parentSessionID: "ses_parent_duplicate", message: { role: "assistant", status: "completed", parts: [] } } } })
if (duplicateCalls.create.length !== 1) throw new Error(`duplicate: expected one child create, got ${duplicateCalls.create.length}`)
if (duplicateCalls.promptAsync.length !== 1) throw new Error(`duplicate: expected one promptAsync, got ${duplicateCalls.promptAsync.length}`)

const statePath = path.join(fixture, ".context-governor-handoffs.jsonl")
const state = fs.readFileSync(statePath, "utf8")
if (!state.includes('"parentKind":"subagent"')) throw new Error("state file missing subagent parent kind")
if (!state.includes('"mode":"prepare-only"')) throw new Error("state file missing prepare-only subagent record")
if (!state.includes('"mode":"prompt-async"')) throw new Error("state file missing inherited prompt-async subagent record")
console.log("auto-continue subagent smoke validation passed")
NODE
