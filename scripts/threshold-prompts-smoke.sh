#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/context-governor-threshold-prompts.XXXXXX)"
cleanup() {
  local status=$?
  if [ "$status" -eq 0 ]; then
    rm -rf "$FIXTURE"
  else
    printf 'threshold prompts smoke failed; fixture left at %s\n' "$FIXTURE" >&2
  fi
}
trap cleanup EXIT

FIXTURE="$FIXTURE" REPO_ROOT="$REPO_ROOT" node --input-type=module <<'NODE'
const { default: plugin } = await import(`file://${process.env.REPO_ROOT}/src/plugin.js`)

const PROCEDURE_PROMPT = "PROCEDURAL_REFLECTION_PROMPT: review procedure, skills, task workflow, instruction improvements, smoke tests, handoff conventions, and durable learnings."

function makeCtx() {
  const calls = { create: [], promptAsync: [] }
  return {
    calls,
    ctx: {
      directory: process.env.FIXTURE,
      client: {
        session: {
          async create(args) {
            calls.create.push(args)
            return { id: `ses_child_${calls.create.length}` }
          },
          async promptAsync(args) {
            calls.promptAsync.push(args)
            return { ok: true }
          },
        },
      },
    },
  }
}

function countPrompt(systemItems, text = PROCEDURE_PROMPT) {
  return systemItems.filter((item) => String(item).includes(text)).length
}

async function injectsOnce() {
  const { ctx } = makeCtx()
  const hooks = await plugin.server(ctx, {
    informThreshold: 999999,
    warnThreshold: 999999,
    handoffThreshold: 999999,
    thresholdPrompts: [{ name: "procedure-reflection", threshold: 0, prompt: PROCEDURE_PROMPT }],
  })
  const first = { system: [] }
  const second = { system: [] }
  const input = { sessionID: "ses_once", model: { id: "test", providerID: "test", limit: { context: 1000 } } }
  await hooks["experimental.chat.system.transform"](input, first)
  await hooks["experimental.chat.system.transform"](input, second)
  const total = countPrompt(first.system) + countPrompt(second.system)
  if (total !== 1) throw new Error(`expected reflection prompt once, got ${total}`)
}

async function reflectionDoesNotAutoContinue() {
  const { ctx, calls } = makeCtx()
  const hooks = await plugin.server(ctx, {
    autoContinue: "prompt-async",
    informThreshold: 999999,
    warnThreshold: 999999,
    handoffThreshold: 999999,
    thresholdPrompts: [{ name: "procedure-reflection", threshold: 0, prompt: PROCEDURE_PROMPT }],
  })
  const output = { system: [] }
  await hooks["experimental.chat.system.transform"](
    { sessionID: "ses_no_auto", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
    output,
  )
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_no_auto" } } })
  if (countPrompt(output.system) !== 1) throw new Error("reflection prompt did not inject")
  if (calls.create.length !== 0) throw new Error(`reflection alone must not create child sessions, got ${calls.create.length}`)
  if (calls.promptAsync.length !== 0) throw new Error(`reflection alone must not prompt child sessions, got ${calls.promptAsync.length}`)
}

async function appliesToSubagent() {
  const { ctx } = makeCtx()
  const hooks = await plugin.server(ctx, {
    informThreshold: 999999,
    warnThreshold: 999999,
    handoffThreshold: 999999,
    thresholdPrompts: [{ name: "subagent-procedure-reflection", threshold: 0, appliesTo: "subagent", prompt: PROCEDURE_PROMPT }],
  })

  const orchestrator = { system: [] }
  await hooks["experimental.chat.system.transform"](
    { sessionID: "ses_orchestrator", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
    orchestrator,
  )
  if (countPrompt(orchestrator.system) !== 0) throw new Error("subagent prompt injected into orchestrator")

  await hooks["tool.execute.after"](
    { sessionID: "ses_parent", tool: "task" },
    { output: "task started", metadata: { parentSessionId: "ses_parent", sessionId: "ses_subagent" } },
  )
  const subagent = { system: [] }
  await hooks["experimental.chat.system.transform"](
    { sessionID: "ses_subagent", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
    subagent,
  )
  if (countPrompt(subagent.system) !== 1) throw new Error("subagent prompt did not inject into marked subagent")
}

async function invalidPromptsIgnored() {
  const { ctx } = makeCtx()
  const hooks = await plugin.server(ctx, {
    informThreshold: 999999,
    warnThreshold: 999999,
    handoffThreshold: 999999,
    thresholdPrompts: [
      null,
      { name: "missing-threshold", prompt: PROCEDURE_PROMPT },
      { name: "bad-threshold", threshold: -1, prompt: PROCEDURE_PROMPT },
      { name: "missing-prompt", threshold: 0 },
      { name: "empty-prompt", threshold: 0, prompt: "   " },
    ],
  })
  const output = { system: [] }
  await hooks["experimental.chat.system.transform"](
    { sessionID: "ses_invalid", model: { id: "test", providerID: "test", limit: { context: 1000 } } },
    output,
  )
  if (countPrompt(output.system) !== 0) throw new Error("invalid prompts should be ignored")
}

await injectsOnce()
await reflectionDoesNotAutoContinue()
await appliesToSubagent()
await invalidPromptsIgnored()
console.log("threshold prompts smoke validation passed")
NODE
