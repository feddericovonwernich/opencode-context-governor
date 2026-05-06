# OpenCode Context Governor

OpenCode server plugin that makes the model aware of its context budget and can force a handoff instruction after a configured token threshold, without forking OpenCode.

It is intentionally conservative and plugin-only:

- Anchors on exact provider-reported `step-finish.tokens.input` from OpenCode events.
- Estimates tokens added after the last exact count from user text and tool output.
- Injects an ephemeral system note through `experimental.chat.system.transform`.
- Appends warnings to large tool outputs through `tool.execute.after` when near/over threshold.
- Optionally mutates the current user message's system instruction at handoff threshold.

## Local project usage

In any project, add `.opencode/opencode.json`:

```json
{
  "plugin": [
    [
      "/home/fedderico/Workspace/projects/opencode-context-governor/src/plugin.js",
      {
        "enabled": true,
        "informThreshold": 120000,
        "warnThreshold": 140000,
        "handoffThreshold": 150000,
        "reserveOutputTokens": 12000,
        "estimateCharsPerToken": 3,
        "noteMode": "always",
        "appendToolWarnings": true,
        "mutateUserMessageAtHandoff": true,
        "log": false,
        "handoffInstruction": "Write a handoff letter and stop. Include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps."
      }
    ]
  ]
}
```

For quick testing, use very low thresholds:

```json
{
  "plugin": [
    [
      "/home/fedderico/Workspace/projects/opencode-context-governor/src/plugin.js",
      {
        "informThreshold": 1,
        "warnThreshold": 20,
        "handoffThreshold": 40,
        "reserveOutputTokens": 0,
        "estimateCharsPerToken": 3,
        "noteMode": "always",
        "log": true
      }
    ]
  ]
}
```

The debug log, when enabled, is written to:

`.context-governor.log`

## Options

- `enabled`: default `true`
- `informThreshold`: default `120000`
- `warnThreshold`: default `140000`
- `handoffThreshold`: default `150000`
- `reserveOutputTokens`: default `12000`
- `estimateCharsPerToken`: default `3`; lower means more conservative
- `noteMode`: `always`, `warn`, or `handoff`
- `appendToolWarnings`: append budget warning to tool output after warning/handoff threshold
- `mutateUserMessageAtHandoff`: add a persistent current-turn system instruction when user message itself crosses threshold
- `log`: write debug log in the project `.opencode` directory
- `handoffInstruction`: custom instruction used when threshold is crossed

## Limitations

This plugin does not have exact access to the final provider request token count. It uses exact last-known input tokens plus conservative estimates. That is good enough for thresholds like 150k on a 200k model, but not for riding right up to the hard context limit.
