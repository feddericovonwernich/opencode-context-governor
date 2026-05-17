# Subagent-Aware Auto-Continue Policy Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add a subagent-aware auto-continue policy so orchestrator sessions can use full `prompt-async` handoff while Task/subagent sessions default to safe `prepare-only` behavior and do not steal TUI focus.

**Architecture:** Keep existing per-session state in `src/plugin.js`, add session classification (`orchestrator`, `subagent`, `continuation-child`) and compute an effective auto-continue mode/select-TUI policy per session. Use conservative detection: if a session is created as a continuation child mark it directly; if runtime Task metadata is not explicit, allow deterministic test hooks/options and preserve safe defaults. Add smokes that simulate subagent sessions and live Task-tool behavior.

**Tech Stack:** OpenCode server plugin hooks, Node ESM, bash smoke scripts, OpenCode CLI.

---

## Requirements

1. Existing behavior for non-subagent sessions must remain unchanged unless new options are set.
2. Add options:
   - `autoContinueSubagents`: `inherit | off | prepare-only | prompt-async`, default `prepare-only`.
   - `autoContinueSelectTuiForSubagents`: boolean, default `false`.
3. Existing `autoContinue` remains `off | prepare-only | prompt-async`, default `off`.
4. For subagent sessions, effective mode comes from `autoContinueSubagents`:
   - `inherit` -> use `autoContinue`.
   - otherwise use configured subagent mode.
5. For continuation children, preserve `chainDepth` and parent relation; do not accidentally classify parent orchestrator as subagent.
6. TUI select for subagents must be disabled by default even if `autoContinueSelectTui` is true.
7. Smoke coverage must prove:
   - default subagent policy uses `prepare-only` (`noReply: true`) when global `autoContinue` is `prompt-async`.
   - `autoContinueSubagents: "off"` creates no child.
   - `autoContinueSubagents: "inherit"` preserves full prompt-async behavior.
   - duplicate prevention still creates only one child.
8. Docs must explain that plugin-created child sessions of subagents do not transparently return to the original Task-tool call.

---

## Task 1: Investigate real Task/subagent event metadata

**Objective:** Determine whether current OpenCode events expose a reliable way to identify subagent sessions.

**Files:**
- Read: `test-fixture-subagent/.context-governor.log` if present.
- Read: `test-fixture-subagent/.opencode/command/subagent-governor-smoke.md`.
- Read: `src/plugin.js` event extraction helpers.
- Optional temp fixture under `/tmp`; clean it afterward.

**Steps:**
1. Run or inspect a subagent smoke with logging enabled.
2. Check event shapes/logs for explicit metadata: parent session ID, command `subtask`, task tool input/output, child session ID, agent metadata.
3. Return a Spanish summary with:
   - best available detection method,
   - whether detection is reliable enough for production,
   - recommended fallback if metadata is insufficient.

**Expected:** If OpenCode does not expose enough metadata, implement deterministic policy support via an option/test hook and conservative docs rather than hallucinating perfect detection.

---

## Task 2: Implement config, state, and effective policy

**Objective:** Add subagent-aware config and route auto-continue decisions through effective mode/select helpers.

**Files:**
- Modify: `src/plugin.js`.

**Implementation guidance:**
- Add defaults:
  ```js
  autoContinueSubagents: "prepare-only",
  autoContinueSelectTuiForSubagents: false,
  ```
- Add normalizer for subagent mode:
  ```js
  function normalizeSubagentAutoContinueMode(value) {
    return ["inherit", "off", "prepare-only", "prompt-async"].includes(value)
      ? value
      : DEFAULTS.autoContinueSubagents
  }
  ```
- Extend session state:
  ```js
  kind: "orchestrator", // orchestrator | subagent | continuation-child
  parentSessionID: undefined,
  ```
- Add helpers:
  ```js
  function effectiveAutoContinueMode(cfg, state) { ... }
  function shouldSelectTuiForSession(cfg, state) { ... }
  function isSubagentSession(state) { ... }
  ```
- Change `createContinuationSession` to use effective mode for `noReply`, logging, and JSONL record.
- Change `selectTuiSession` to receive state or boolean so it respects `autoContinueSelectTuiForSubagents`.
- Set child state:
  ```js
  childState.kind = "continuation-child"
  childState.parentSessionID = state.sessionID
  childState.chainDepth = state.chainDepth + 1
  ```
- Add a conservative detection hook for tests/runtime if event metadata exists. If no reliable metadata exists, implement a small helper that marks a session subagent when event/input includes clear flags only, e.g. `input.subtask === true`, `input.command?.subtask === true`, `event.properties.session?.subtask === true`, `event.properties.subtask === true`. Do not guess based only on multiple sessions.

**Verification:** Existing smokes should still pass.

---

## Task 3: Add deterministic subagent policy smokes

**Objective:** Add mock-based smoke scripts that directly validate effective policy without relying on expensive model calls.

**Files:**
- Create: `scripts/auto-continue-subagent-smoke.sh`.
- Modify: `package.json`.

**Test design:**
Use Node with mocked `ctx.client.session.create`, `promptAsync`, and `_client.post`, like existing auto smokes. Mark the test session as subagent via whichever explicit marker the implementation supports, ideally an event/input shape accepted by the detection helper.

Cases:
1. Global `autoContinue: "prompt-async"`, default `autoContinueSubagents`: subagent handoff creates one child with `noReply: true`, zero or no TUI select calls by default.
2. `autoContinueSubagents: "off"`: no child creation.
3. `autoContinueSubagents: "inherit"`: creates child with `noReply: false`.
4. Duplicate finish/idle events still create exactly one child.

Add package script:
```json
"smoke:auto-subagent": "bash scripts/auto-continue-subagent-smoke.sh"
```

Add it to `npm run check` bash syntax validation.

---

## Task 4: Docs update

**Objective:** Document behavior and recommendations.

**Files:**
- Modify: `README.md`.

Add section under Auto-continue:
- Explain orchestrator vs subagent sessions.
- Explain Task-tool limitation: child session created by plugin does not automatically return result to original Task call.
- Recommended config:
  ```json
  {
    "autoContinue": "prompt-async",
    "autoContinueSubagents": "prepare-only",
    "autoContinueSelectTuiForSubagents": false
  }
  ```
- Options list includes new options.

---

## Task 5: Verify and commit

Run:
```bash
npm run check
npm run smoke:auto-prepare
npm run smoke:auto-prompt-async
npm run smoke:auto-subagent
npm run smoke
npm run smoke:subagent
```

Then:
```bash
git diff --check
git status --short --branch
git diff --stat HEAD
```

Commit:
```bash
git add README.md package.json src/plugin.js scripts/auto-continue-subagent-smoke.sh docs/plans/2026-05-17-subagent-aware-auto-continue.md
git commit -m "feat: add subagent-aware auto-continue policy"
```
