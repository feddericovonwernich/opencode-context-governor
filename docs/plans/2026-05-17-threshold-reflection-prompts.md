# Threshold-triggered procedural reflection prompts

## Goal

Add configurable prompts that fire at token thresholds before handoff, with the first supported use case focused on procedural reflection: the agent should reflect on the procedure, skills, and tasks it has been executing, then propose improvements to instructions or record learnings before context quality degrades.

This should complement, not replace, the existing `informThreshold` / `warnThreshold` / `handoffThreshold` behavior and the auto-continue handoff flow.

## User requirement

Federico wants a pre-handoff reflection threshold. The reflection should not be generic task planning. It should ask the agent to review the workflow it has been following:

- procedure/process used so far;
- skills or instructions loaded/applied;
- task decomposition and orchestration quality;
- recurring pitfalls or friction;
- improvements to future instructions, skills, docs, smoke tests, or handoff conventions;
- durable learnings worth registering.

The reflection should happen before hard handoff and should not create a child session by itself.

## Backwards compatibility

Existing configs must continue to work unchanged:

- `informThreshold`, `warnThreshold`, `handoffThreshold` still drive the budget note levels.
- `handoffInstruction` remains the special handoff instruction.
- Auto-continue remains tied to the handoff marker and completed handoff, not to reflection prompts.

## Proposed config

Add `thresholdPrompts`, an optional array:

```json
{
  "thresholdPrompts": [
    {
      "name": "procedure-reflection",
      "threshold": 130000,
      "once": true,
      "appliesTo": "all",
      "inject": "system",
      "prompt": "Pause normal execution briefly and reflect on the procedure, skills, and task workflow you have been using. Identify instruction improvements, skill updates, smoke tests, or durable learnings worth recording. Then continue with the next concrete step unless a handoff is required."
    }
  ]
}
```

Suggested fields:

- `name` string, required-ish; fallback to `threshold-prompt-N`.
- `threshold` number >= 0; invalid prompts are ignored.
- `prompt` non-empty string; invalid prompts are ignored.
- `once` boolean; default `true`.
- `appliesTo`: `all | orchestrator | subagent | continuation-child`; default `all`.
- `inject`: for now support `system`; parse and normalize unsupported values to `system`.

## Default reflection prompt

Add a default procedural prompt disabled by default unless explicitly configured? Decision: do **not** auto-enable another threshold in existing installs. Document a recommended snippet. This keeps behavior stable.

However, expose a named shortcut only if simple and tested is preferable. If time is limited, just implement generic `thresholdPrompts` and docs.

Recommended prompt text:

```text
Pause normal execution briefly for a procedural reflection before the context handoff threshold. Review the procedure, skills, and task workflow you have been executing: which instructions/skills were used, whether the task decomposition is still sound, what repeated friction or mistakes appeared, and what should be improved in future instructions, skills, smoke tests, or handoff conventions. If you discover a durable learning, explicitly recommend where it should be recorded. Keep it concise, then continue with the next concrete step unless a handoff is required.
```

## Implementation notes

1. Extend `DEFAULTS` with `thresholdPrompts: []`.
2. Add normalization helpers:
   - validate array;
   - normalize name, threshold, prompt, once, appliesTo, inject;
   - sort by ascending threshold so lower threshold prompt fires first;
   - ignore invalid entries.
3. Extend session state with `triggeredThresholdPrompts`, probably a `Set`.
4. Add helper `applicableThresholdPrompts(cfg, state, estimated)`:
   - prompt threshold crossed;
   - appliesTo matches `state.kind` or `all`;
   - if `once` and already triggered, skip;
   - handoff prompts are **not** represented here in this iteration.
5. Add helper `thresholdPromptNote(prompt, state, cfg, source)` with metadata similar to `budgetNote` and clear tags, e.g. `<context_governor_threshold_prompt name="procedure-reflection">`.
6. Inject prompt notes in `experimental.chat.system.transform` by `output.system.push(...)`.
7. Track `triggeredThresholdPrompts.add(prompt.name)` when actually injected.
8. Do not set `handoffRequested`, `handoffMarkerSeen`, or continuation state for reflection prompts.
9. Logging when `log` enabled:
   - `threshold-prompt session=... name=... threshold=... source=system.transform`.
10. Tool-output warnings should remain existing budget warnings. Do not append reflection prompts to tool output for this iteration unless explicitly requested.

## Tests / smokes

Add `scripts/threshold-prompts-smoke.sh` and package script `smoke:threshold-prompts`.

Test cases with mock plugin hooks:

1. Reflection prompt injects once:
   - configure `thresholdPrompts` with threshold 0, name `procedure-reflection`;
   - run `experimental.chat.system.transform` twice for same session;
   - assert the custom prompt appears exactly once across output system arrays;
   - assert budget note may appear separately but reflection does not duplicate.
2. Reflection does not auto-continue:
   - mock `ctx.client.session.create` and `promptAsync`;
   - trigger reflection threshold but not handoff marker;
   - assert no child session is created.
3. `appliesTo` works:
   - prompt applies to `subagent`; orchestrator session should not get it;
   - mark subagent via `tool.execute.after` task metadata;
   - subagent session should get it.
4. Invalid prompts are ignored without throwing.

Update `npm run check` to bash-check new script.

Run full suite:

```sh
npm run check &&
npm run smoke:threshold-prompts &&
npm run smoke:auto-prepare &&
npm run smoke:auto-prompt-async &&
npm run smoke:auto-subagent &&
npm run smoke &&
npm run smoke:subagent &&
git diff --check
```

## Docs

Update README manual config with an example `thresholdPrompts` block and a section explaining procedural reflection before handoff.

Clarify that reflection prompts are advisory system injections; they do not force stop/handoff and do not trigger auto-continue.

## Commit

After verification, commit as:

```text
feat: add threshold procedural reflection prompts
```
