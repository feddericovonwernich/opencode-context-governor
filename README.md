# OpenCode Context Governor

OpenCode plugin that makes the model aware of its current context-window budget and can force a handoff instruction after a configurable token threshold, without forking OpenCode.

The plugin is intentionally conservative and plugin-only:

- Anchors on exact provider-reported `step-finish.tokens.input` from OpenCode events when available.
- Estimates tokens added after the last exact count from user text and tool output.
- Injects an ephemeral system note through `experimental.chat.system.transform`.
- Appends warnings to large tool outputs through `tool.execute.after` when near or over threshold.
- Optionally mutates the current user message's system instruction at the handoff threshold.

## Quick install

From the root of the project where you want to enable the plugin:

```sh
curl -fsSL https://raw.githubusercontent.com/feddericovonwernich/opencode-context-governor/main/scripts/install.sh | bash
```

Or install into a specific project directory:

```sh
curl -fsSL https://raw.githubusercontent.com/feddericovonwernich/opencode-context-governor/main/scripts/install.sh | bash -s -- /path/to/your/project
```

The installer will:

1. Download `src/plugin.js` into `~/.local/share/opencode-context-governor/plugin.js`.
2. Create or update the project's `.opencode/opencode.json`.
3. Back up any existing OpenCode config before editing it.
4. Ask which threshold preset to use: `production`, `conservative`, or `test`.
5. Ask for the exact token thresholds and handoff instruction.

If you are running the installer non-interactively, it uses production defaults.

## Installer environment variables

You can override the default download location or install directory:

```sh
OPENCODE_CONTEXT_GOVERNOR_RAW_BASE=https://raw.githubusercontent.com/YOUR_USER/opencode-context-governor/main \
OPENCODE_CONTEXT_GOVERNOR_HOME=$HOME/.local/share/opencode-context-governor \
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/opencode-context-governor/main/scripts/install.sh | bash
```

Useful variables:

- `OPENCODE_CONTEXT_GOVERNOR_RAW_BASE`: base URL used by the installer to download `src/plugin.js`.
- `OPENCODE_CONTEXT_GOVERNOR_PLUGIN_URL`: full URL to `plugin.js`; overrides `RAW_BASE`.
- `OPENCODE_CONTEXT_GOVERNOR_HOME`: local directory where the plugin file is installed.

## Manual installation

In any project, create or edit `.opencode/opencode.json`:

```json
{
  "plugin": [
    [
      "/home/fedderico/.local/share/opencode-context-governor/plugin.js",
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
        "autoContinue": "off",
        "autoContinueSubagents": "prepare-only",
        "autoContinueSelectTuiForSubagents": false,
        "log": false,
        "handoffInstruction": "Write a handoff letter and stop. Put CONTEXT_GOVERNOR_HANDOFF on its own line, then include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps."
      }
    ]
  ]
}
```

If you are developing from this repository directly, point OpenCode at the repo copy instead:

```json
{
  "plugin": [
    [
      "/home/fedderico/Workspace/projects/opencode-context-governor/src/plugin.js",
      {
        "informThreshold": 120000,
        "warnThreshold": 140000,
        "handoffThreshold": 150000
      }
    ]
  ]
}
```

## Threshold presets

Suggested real-world starting points for a 200k-token model:

```json
{
  "informThreshold": 120000,
  "warnThreshold": 140000,
  "handoffThreshold": 150000,
  "reserveOutputTokens": 12000
}
```

More conservative settings:

```json
{
  "informThreshold": 90000,
  "warnThreshold": 110000,
  "handoffThreshold": 125000,
  "reserveOutputTokens": 16000
}
```

For quick testing, use very low thresholds:

```json
{
  "informThreshold": 1,
  "warnThreshold": 5,
  "handoffThreshold": 10,
  "reserveOutputTokens": 0,
  "log": true
}
```

## Auto-continue handoff

By default, automatic continuation is disabled (`"autoContinue": "off"`) and existing handoff behavior is unchanged. When enabled, the assistant must include the configured marker (default `CONTEXT_GOVERNOR_HANDOFF`) in its completed handoff response before the plugin creates a child session. The default `handoffInstruction` asks the model to put that marker on its own line.

Safe prepare-only mode creates a child session, deposits the handoff prompt, and does not ask the child model to answer:

```json
{
  "autoContinue": "prepare-only",
  "autoContinueMaxChain": 3,
  "autoContinueSelectTui": true,
  "log": true
}
```

Full prompt-async mode creates the child session and immediately asks it to continue. This can spend additional model calls, so use it only when you want unattended continuation:

```json
{
  "autoContinue": "prompt-async",
  "autoContinueMaxChain": 3,
  "autoContinueSelectTui": true,
  "log": true
}
```

Auto-continue creates the child with the previous session as `parentID`, sends the continuation with OpenCode `session.promptAsync`, and best-effort switches the TUI using OpenCode's internal transport endpoint `/tui/select-session`. That TUI switch is version-sensitive; failures are logged when `log` is enabled but do not fail the handoff.

### Subagent-aware auto-continue

OpenCode Task-tool subagents run in their own sessions. The plugin treats a session as a subagent only when OpenCode exposes explicit Task metadata (for example `tool.execute.after` for `task` with `output.metadata.sessionId`) or deterministic subtask flags used by commands/tests. It does not guess from session counts or titles alone.

Subagents have a separate auto-continue mode so orchestrator sessions can use full unattended continuation while Task sessions stay safe by default:

```json
{
  "autoContinue": "prompt-async",
  "autoContinueSubagents": "prepare-only",
  "autoContinueSelectTuiForSubagents": false
}
```

`autoContinueSubagents` accepts `inherit`, `off`, `prepare-only`, or `prompt-async`; default is `prepare-only`. `inherit` uses the global `autoContinue` mode for subagent sessions. `autoContinueSelectTuiForSubagents` defaults to `false`, so a subagent handoff does not steal focus from the orchestrator TUI even when `autoContinueSelectTui` is enabled.

Important Task-tool limitation: when the plugin creates a continuation child for a subagent, that child session does not transparently return its result to the original Task-tool call. Use the default `prepare-only` policy for subagents unless you explicitly want the subagent continuation to run as a separate follow-up session.

Anti-loop behavior:

- A session can start only one continuation (`continuationStarted` prevents duplicates).
- Continuation requires all of: handoff threshold requested, marker seen, assistant finished/idle, and `autoContinue` not `off`.
- `autoContinueMaxChain` limits nested continuation depth.
- A JSONL audit record is appended to `.context-governor-handoffs.jsonl` by default.

## Agent skill

This repository includes a bundled Hermes skill for agents that need to install, configure, test, or troubleshoot the plugin:

```text
skills/opencode-context-governor/SKILL.md
```

The skill gives agents a repeatable workflow for:

- using the curl installer,
- manually editing `.opencode/opencode.json`,
- choosing production, conservative, or test thresholds,
- running smoke tests,
- debugging plugin-load issues,
- preserving existing OpenCode config safely.

If you want to use it as a personal Hermes skill, copy or symlink it into your Hermes skills directory, for example:

```sh
mkdir -p ~/.hermes/skills/opencode-context-governor
cp skills/opencode-context-governor/SKILL.md ~/.hermes/skills/opencode-context-governor/SKILL.md
```

## Test locally

From this repository:

```sh
npm run check
npm run smoke
npm run smoke:subagent
npm run smoke:auto-prepare
npm run smoke:auto-prompt-async
npm run smoke:auto-subagent
```

The top-level smoke test uses `test-fixture/.opencode/opencode.json`, which has tiny thresholds so handoff triggers immediately.

The subagent smoke test uses `test-fixture-subagent/.opencode/opencode.json` plus a deterministic OpenCode command:

```text
test-fixture-subagent/.opencode/command/subagent-governor-smoke.md
```

That command is marked `agent: general` and `subtask: true`, so OpenCode creates a real Task-tool subagent session without relying on the primary model to decide to call the Task tool.

Expected behavior: OpenCode should run, the plugin should inject a context-budget handoff instruction, and the model should stop with a handoff message. For the subagent smoke test, validation also checks that `.context-governor.log` contains at least two session IDs: the primary session and the subagent session.

## Options

- `enabled`: default `true`.
- `informThreshold`: default `120000`.
- `warnThreshold`: default `140000`.
- `handoffThreshold`: default `150000`.
- `reserveOutputTokens`: default `12000`.
- `estimateCharsPerToken`: default `3`; lower means more conservative.
- `noteMode`: `always`, `warn`, or `handoff`.
- `appendToolWarnings`: append budget warning to tool output after warning or handoff threshold.
- `mutateUserMessageAtHandoff`: add a current-turn system instruction when the user message itself crosses threshold.
- `log`: write debug log to `.context-governor.log` in the project root.
- `handoffInstruction`: custom instruction used when threshold is crossed.
- `autoContinue`: `off`, `prepare-only`, or `prompt-async`; default `off`.
- `autoContinueSubagents`: `inherit`, `off`, `prepare-only`, or `prompt-async` for explicit Task/subagent sessions; default `prepare-only`.
- `autoContinueSelectTui`: best-effort switch to the child session in the OpenCode TUI; default `true`.
- `autoContinueSelectTuiForSubagents`: allow TUI switching for subagent-created continuation children; default `false`.
- `autoContinueMaxChain`: maximum nested auto-continuation depth; default `3`.
- `autoContinueHandoffMarker`: required marker in the assistant handoff; default `CONTEXT_GOVERNOR_HANDOFF`.
- `autoContinueStateFile`: JSONL audit file; default `.context-governor-handoffs.jsonl`.
- `autoContinueTitlePrefix`: title prefix used for child continuation sessions.
- `autoContinueInstruction`: instruction prepended to the handoff text sent to the child session.

## Debug log

When `log` is `true`, the plugin writes:

```text
.context-governor.log
```

The log is intentionally local and ignored by git.

## Limitations

OpenCode plugin hooks do not expose an exact preflight token count for the final provider request. This plugin uses exact last-known provider usage plus conservative estimates for newly added content.

That is reliable enough for operational thresholds, for example handing off around 150k on a 200k model. It is not meant for riding right up to the model's hard context limit.
