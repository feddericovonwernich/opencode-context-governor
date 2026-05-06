#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../test-fixture-subagent"
rm -f .context-governor.log

PROMPT="$({
  node - <<'NODE'
process.stdout.write(
  "SUBAGENT_CONTEXT_TEST ".repeat(700) +
    "If you see a context-governor handoff instruction, follow it exactly. Otherwise reply exactly SUBAGENT_DONE and stop.",
)
NODE
})"

OUTPUT_FILE=".subagent-smoke-output.txt"
rm -f "$OUTPUT_FILE"

opencode run --command subagent-governor-smoke "$PROMPT" | tee "$OUTPUT_FILE"

node - <<'NODE'
const fs = require("node:fs")
const log = fs.readFileSync(".context-governor.log", "utf8")
const output = fs.readFileSync(".subagent-smoke-output.txt", "utf8")
const sessions = [...log.matchAll(/session=(ses_[A-Za-z0-9]+)/g)].map((m) => m[1])
const uniqueSessions = new Set(sessions)
const handoffSession = [...log.matchAll(/(chat\.message|system\.transform) session=(ses_[A-Za-z0-9]+).*level=handoff/g)].map((m) => m[2])
const hasSubagentHandoff = handoffSession.some((session) => uniqueSessions.has(session))
const hasTaskToolAfter = /tool\.after session=ses_[A-Za-z0-9]+ tool=task/.test(log)
const outputHasHandoff = output.includes("SUBAGENT_CONTEXT_GOVERNOR_HANDOFF")

if (uniqueSessions.size < 2) {
  console.error("Expected at least two sessions in context-governor log: primary + subagent")
  process.exit(1)
}
if (!hasSubagentHandoff) {
  console.error("Expected a handoff-level chat.message or system.transform entry")
  process.exit(1)
}
if (!hasTaskToolAfter) {
  console.error("Expected task tool completion in primary session")
  process.exit(1)
}
if (!outputHasHandoff) {
  console.error("Expected OpenCode output to include SUBAGENT_CONTEXT_GOVERNOR_HANDOFF")
  process.exit(1)
}

console.log("subagent smoke validation passed")
console.log(`sessions observed: ${[...uniqueSessions].join(", ")}`)
NODE
