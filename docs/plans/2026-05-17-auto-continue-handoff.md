# Auto-Continue Handoff Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add automatic OpenCode handoff continuation to the context governor plugin: create a child session, inject the handoff, switch TUI to the child, and optionally continue automatically.

**Architecture:** Keep existing behavior as default with `autoContinue: "off"`. When a handoff marker is detected in a completed assistant response, the plugin creates a child session via `ctx.client.session.create`, sends a continuation prompt via `ctx.client.session.promptAsync`, and best-effort switches the TUI via `ctx.client._client.post({ url: "/tui/select-session" })`. Anti-loop state prevents duplicate child creation and enforces max chain depth.

**Tech Stack:** OpenCode plugin JS ESM, Node.js, bash smoke scripts.

---

## MVP Scope

Implement:

- `autoContinue: "off" | "prepare-only" | "prompt-async"`, default `"off"`.
- `autoContinueSelectTui`, default `true`.
- `autoContinueMaxChain`, default `3`.
- `autoContinueHandoffMarker`, default `CONTEXT_GOVERNOR_HANDOFF`.
- `autoContinueStateFile`, default `.context-governor-handoffs.jsonl`.
- `autoContinueTitlePrefix`.
- `autoContinueInstruction`.
- Updated default `handoffInstruction` requiring the marker.
- Handoff detection from assistant text events and finish/idle events.
- Child session creation with `parentID`.
- `prepare-only`: child receives prompt with `noReply: true`.
- `prompt-async`: child continues with `noReply: false`.
- Best-effort TUI select using `ctx.client._client.post`.
- Deterministic smoke fixture/scripts for no-op checks and auto-continue path.

Defer:

- Archiving parent sessions.
- Compaction fallback.
- Fancy UI/status messages beyond logs.

---

## Task 1: Add normalized config and state helpers

**Files:**
- Modify: `src/plugin.js`

**Steps:**
1. Extend `DEFAULTS` with the auto-continue options above.
2. Add `normalizeAutoContinueMode` and normalize all new options in `normalizeOptions`.
3. Extend per-session state from `getSession` with fields for handoff/continuation:
   - `handoffRequested`
   - `handoffMarkerSeen`
   - `handoffText`
   - `assistantFinished`
   - `continuationStarted`
   - `childSessionID`
   - `chainDepth`
4. Add small helpers to extract event type/session/text and write JSONL state.
5. Run `npm run check`.

**Acceptance:** With defaults, existing behavior remains off-compatible and `npm run check` passes.

---

## Task 2: Require marker and detect completed handoff

**Files:**
- Modify: `src/plugin.js`

**Steps:**
1. Update `DEFAULTS.handoffInstruction` to require `CONTEXT_GOVERNOR_HANDOFF` on its own line.
2. When level is `handoff`, mark `state.handoffRequested = true`.
3. In `event`, collect assistant text deltas/updates per session when a handoff was requested.
4. Mark `handoffMarkerSeen` when accumulated text includes the configured marker.
5. Mark `assistantFinished` on assistant `step-finish`, completed assistant message, or `session.idle` for a marker-seen session.
6. Only trigger continuation when all conditions hold:
   - `cfg.autoContinue !== "off"`
   - `handoffRequested`
   - `handoffMarkerSeen`
   - `assistantFinished`
   - `!continuationStarted`
   - `chainDepth < autoContinueMaxChain`

**Acceptance:** Logs clearly show request, marker seen, and continuation trigger.

---

## Task 3: Implement child creation, prompt injection, and TUI select

**Files:**
- Modify: `src/plugin.js`

**Steps:**
1. Add `buildContinuationPrompt` with previous session ID, chain depth, handoff text, and `autoContinueInstruction`.
2. Add `createContinuationSession(ctx, cfg, state, input/session metadata)`.
3. Create child with `ctx.client.session.create({ query: { directory: ctx.directory }, body: { parentID, title } })`.
4. Send continuation prompt using `ctx.client.session.promptAsync({ path: { id: childID }, query: { directory }, body: { agent, noReply, parts } })`.
5. For `prepare-only`, use `noReply: true`; for `prompt-async`, `noReply: false`.
6. Add `selectTuiSession` using `ctx.client._client.post({ url: "/tui/select-session", query: { directory }, body: { sessionID } })`.
7. Call select immediately after child creation and after prompt dispatch. If it fails, log but do not throw.
8. Append state to JSONL.

**Acceptance:** Prepare-only deposits handoff. Prompt-async causes a child assistant response. TUI select logs `data:true` when running in TUI.

---

## Task 4: Add smoke scripts and package scripts

**Files:**
- Modify: `package.json`
- Create: `scripts/auto-continue-prepare-smoke.sh`
- Create: `scripts/auto-continue-prompt-async-smoke.sh`

**Steps:**
1. Add scripts:
   - `smoke:auto-prepare`
   - `smoke:auto-prompt-async`
2. Scripts should create temp fixtures under `/tmp`, write a local `opencode.json`, run OpenCode with low thresholds and deterministic marker prompts, verify log/state files, and clean/leave only on failure.
3. Avoid requiring a long-lived TUI for the default check if possible. Keep TUI validation manual or bounded.
4. Include bash syntax in `npm run check`.

**Acceptance:** `npm run check` passes. At least one auto-continue smoke passes in this environment.

---

## Task 5: Docs

**Files:**
- Modify: `README.md`

**Steps:**
1. Document the new config options.
2. Add safe examples for `prepare-only` and `prompt-async`.
3. Explain that TUI selection uses best-effort OpenCode internal transport and is version-sensitive.
4. Explain anti-loop behavior and cost warning for `prompt-async`.

**Acceptance:** README tells a user how to enable the feature safely.

---

## Verification Commands

Run from repo root:

```bash
npm run check
npm run smoke:auto-prepare
npm run smoke:auto-prompt-async
```

Then inspect:

```bash
git status --short --branch
git diff -- src/plugin.js package.json README.md scripts/auto-continue-prepare-smoke.sh scripts/auto-continue-prompt-async-smoke.sh
```
