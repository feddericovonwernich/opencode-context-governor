---
name: opencode-context-governor
description: Use when installing, configuring, testing, or troubleshooting the OpenCode Context Governor plugin in a project. Guides agents through curl installer usage, manual .opencode/opencode.json setup, threshold selection, auto-continue, procedural reflection prompts, and verification.
version: 1.2.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [opencode, plugin, context-window, tokens, handoff, installer]
    related_skills: [opencode]
---

# OpenCode Context Governor

## Overview

OpenCode Context Governor is a plugin-only context-budget guard for OpenCode. It makes the model aware of approximate context-window usage, can inject configurable procedural reflection prompts at token thresholds, and can force a handoff once a configurable token threshold is crossed.

Use this skill when an agent needs to install the plugin into a project, configure `.opencode/opencode.json`, choose sane token thresholds, configure auto-continue or threshold reflection prompts, run low-threshold smoke tests, or troubleshoot whether OpenCode loaded the plugin.

The plugin intentionally avoids forking OpenCode. It uses supported OpenCode plugin hooks and conservative token estimates. Exact preflight provider request token counts are not available through plugin hooks, so thresholds should leave safety margin.

## When to Use

Use this skill when:

- The user asks to install OpenCode Context Governor in a project.
- The user asks to configure OpenCode to become context-window aware.
- The user wants agents to hand off automatically near a context limit.
- The user wants pre-handoff procedural reflection about skills, instructions, task workflow, or durable learnings.
- The user wants a one-line curl installer for the plugin.
- The user wants a low-threshold test configuration to prove handoff behavior.
- An existing installation is not triggering context notes or handoff.

Do not use this skill for:

- General OpenCode usage unrelated to context budgeting.
- Changing OpenCode core internals or maintaining an OpenCode fork.
- Exact tokenizer-level accounting. This plugin is operationally conservative, not mathematically exact.

## Repository Layout

Expected repository layout:

```text
opencode-context-governor/
  README.md
  package.json
  scripts/install.sh
  scripts/update-agent-skill.sh
  scripts/update-hermes-skill.sh
  scripts/subagent-smoke.sh
  scripts/auto-continue-prepare-smoke.sh
  scripts/auto-continue-prompt-async-smoke.sh
  scripts/auto-continue-subagent-smoke.sh
  scripts/threshold-prompts-smoke.sh
  src/plugin.js
  skills/opencode-context-governor/SKILL.md
  test-fixture/.opencode/opencode.json
  test-fixture-subagent/.opencode/opencode.json
  test-fixture-subagent/.opencode/command/subagent-governor-smoke.md
```

Key files:

- `src/plugin.js`: the OpenCode plugin.
- `scripts/install.sh`: guided installer for end users.
- `scripts/update-agent-skill.sh`: generalized local updater that finds/installs this bundled skill for OpenCode, Hermes, Claude-compatible, or generic agent-compatible skill directories.
- `scripts/update-hermes-skill.sh`: compatibility wrapper around `scripts/update-agent-skill.sh --harness hermes`.
- `README.md`: human-facing installation and configuration instructions.
- `test-fixture/.opencode/opencode.json`: low-threshold fixture for smoke testing.
- `scripts/subagent-smoke.sh`: deterministic subagent smoke test. It invokes an OpenCode command with `agent: general` and `subtask: true` so the Task-tool subagent path runs without relying on model choice.
- `test-fixture-subagent/.opencode/command/subagent-governor-smoke.md`: command used by the subagent smoke test.
- `scripts/auto-continue-prepare-smoke.sh`: deterministic mock smoke for prepare-only continuation.
- `scripts/auto-continue-prompt-async-smoke.sh`: deterministic mock smoke for prompt-async continuation.
- `scripts/auto-continue-subagent-smoke.sh`: deterministic mock smoke for subagent-aware continuation policy.
- `scripts/threshold-prompts-smoke.sh`: deterministic mock smoke for threshold-triggered procedural reflection prompts.

## Fast Installation Path

From the project where the user wants the plugin enabled, run:

```sh
curl -fsSL https://raw.githubusercontent.com/feddericovonwernich/opencode-context-governor/main/scripts/install.sh | bash
```

To install into a specific project path:

```sh
curl -fsSL https://raw.githubusercontent.com/feddericovonwernich/opencode-context-governor/main/scripts/install.sh | bash -s -- /path/to/project
```

The installer should:

1. Download `src/plugin.js` into `~/.local/share/opencode-context-governor/plugin.js`.
2. Create or update `/path/to/project/.opencode/opencode.json`.
3. Back up an existing config as `opencode.json.bak.<timestamp>` before editing.
4. Prompt for threshold preset and values when a TTY is available.
5. Use production defaults when run non-interactively.

## Installer Environment Variables

Use these when installing from a fork, local raw server, or alternate destination:

```sh
OPENCODE_CONTEXT_GOVERNOR_RAW_BASE=https://raw.githubusercontent.com/YOUR_USER/opencode-context-governor/main \
OPENCODE_CONTEXT_GOVERNOR_HOME=$HOME/.local/share/opencode-context-governor \
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/opencode-context-governor/main/scripts/install.sh | bash
```

Variables:

- `OPENCODE_CONTEXT_GOVERNOR_RAW_BASE`: base URL used to fetch repository files.
- `OPENCODE_CONTEXT_GOVERNOR_PLUGIN_URL`: direct URL for `plugin.js`; overrides `RAW_BASE`.
- `OPENCODE_CONTEXT_GOVERNOR_HOME`: local directory where `plugin.js` is installed.

## Updating This Agent Skill

If the target machine uses OpenCode, install or update this skill from a fresh checkout with:

```sh
scripts/update-agent-skill.sh --harness opencode
```

This writes the OpenCode global skill copy to `~/.config/opencode/skills/opencode-context-governor/SKILL.md` by default. For a project-local OpenCode skill, use:

```sh
scripts/update-agent-skill.sh --harness opencode --project-dir /path/to/project
```

The same updater supports other agent harnesses:

```sh
scripts/update-agent-skill.sh --harness hermes
scripts/update-agent-skill.sh --harness claude
scripts/update-agent-skill.sh --harness agents
scripts/update-agent-skill.sh --harness all --dry-run
```

Useful options:

```sh
scripts/update-agent-skill.sh --dry-run
scripts/update-agent-skill.sh --no-install
scripts/update-agent-skill.sh --harness hermes --hermes-home ~/.hermes/profiles/wiki-importacion-china
scripts/update-agent-skill.sh --harness opencode --opencode-home ~/.config/opencode
scripts/update-agent-skill.sh --harness opencode --target-dir ~/.config/opencode/skills/opencode-context-governor
```

The script searches the selected harness' skill roots for a skill named `opencode-context-governor`, backs up an existing `SKILL.md`, then copies or exports `skills/opencode-context-governor/SKILL.md` from the repository. If no installed copy is found, it installs into that harness' default skill directory unless `--no-install` is set.

Use `--dry-run` first on unfamiliar machines. The older `scripts/update-hermes-skill.sh` entrypoint remains as a Hermes-only compatibility wrapper.

## Manual Configuration

If the installer is not appropriate, write the OpenCode config manually.

Create or edit `.opencode/opencode.json` in the target project:

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
        "thresholdPrompts": [
          {
            "name": "procedure-reflection",
            "threshold": 130000,
            "once": true,
            "appliesTo": "all",
            "inject": "system",
            "prompt": "Pause normal execution briefly for a procedural reflection before the context handoff threshold. Review the procedure, skills, and task workflow you have been executing: which instructions/skills were used, whether the task decomposition is still sound, what repeated friction or mistakes appeared, and what should be improved in future instructions, skills, smoke tests, or handoff conventions. If you discover a durable learning, explicitly recommend where it should be recorded. Keep it concise, then continue with the next concrete step unless a handoff is required."
          }
        ],
        "autoContinue": "off",
        "autoContinueSubagents": "prepare-only",
        "autoContinueSelectTui": true,
        "autoContinueSelectTuiForSubagents": false,
        "autoContinueMaxChain": 3,
        "log": false,
        "handoffInstruction": "Write a handoff letter and stop. Put CONTEXT_GOVERNOR_HANDOFF on its own line, then include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps."
      }
    ]
  ]
}
```

When developing from a local checkout, point directly at the repository copy:

```json
{
  "plugin": [
    [
      "/home/fedderico/Workspace/projects/opencode-context-governor/src/plugin.js",
      {
        "enabled": true,
        "informThreshold": 120000,
        "warnThreshold": 140000,
        "handoffThreshold": 150000
      }
    ]
  ]
}
```

If `.opencode/opencode.json` already contains other plugins, preserve them and append this plugin entry. Do not overwrite unrelated OpenCode settings.

## Choosing Thresholds

For a 200k-token model, production defaults are:

```json
{
  "informThreshold": 120000,
  "warnThreshold": 140000,
  "handoffThreshold": 150000,
  "reserveOutputTokens": 12000
}
```

Use conservative defaults when the model has lower context, tool output tends to be large, or handoff must happen earlier:

```json
{
  "informThreshold": 90000,
  "warnThreshold": 110000,
  "handoffThreshold": 125000,
  "reserveOutputTokens": 16000
}
```

Use test thresholds only to verify behavior quickly:

```json
{
  "informThreshold": 1,
  "warnThreshold": 5,
  "handoffThreshold": 10,
  "reserveOutputTokens": 0,
  "log": true
}
```

Do not set `handoffThreshold` close to the advertised context maximum. The plugin is conservative, but it does not have exact final request token counts.

## Procedural Reflection Prompts

Use `thresholdPrompts` for pre-handoff reflection that improves future agent behavior without stopping the current task. These prompts are injected as system notes when the estimated token threshold is crossed. They do **not** request handoff, do **not** create child sessions, and do **not** trigger auto-continue.

Recommended pre-handoff reflection for agent workflows:

```json
{
  "thresholdPrompts": [
    {
      "name": "procedure-reflection",
      "threshold": 130000,
      "once": true,
      "appliesTo": "all",
      "inject": "system",
      "prompt": "Pause normal execution briefly for a procedural reflection before the context handoff threshold. Review the procedure, skills, and task workflow you have been executing: which instructions/skills were used, whether the task decomposition is still sound, what repeated friction or mistakes appeared, and what should be improved in future instructions, skills, smoke tests, or handoff conventions. If you discover a durable learning, explicitly recommend where it should be recorded. Keep it concise, then continue with the next concrete step unless a handoff is required."
    }
  ]
}
```

Supported fields:

- `name`: stable prompt identifier used for once-per-session tracking.
- `threshold`: token estimate at which to inject the prompt.
- `prompt`: instruction text.
- `once`: defaults to `true`; set `false` only for prompts that should repeat every request after crossing the threshold.
- `appliesTo`: `all`, `orchestrator`, `subagent`, or `continuation-child`.
- `inject`: currently normalized to `system`.

## Auto-Continue Handoff

Automatic continuation is opt-in. Keep `autoContinue: "off"` unless the user explicitly wants unattended continuation.

Safe prepare-only mode creates a child session, deposits the handoff prompt, and does not ask the child model to answer:

```json
{
  "autoContinue": "prepare-only",
  "autoContinueMaxChain": 3,
  "autoContinueSelectTui": true
}
```

Full prompt-async mode creates the child session and immediately asks it to continue:

```json
{
  "autoContinue": "prompt-async",
  "autoContinueMaxChain": 3,
  "autoContinueSelectTui": true
}
```

For Task-tool subagents, prefer the default conservative policy:

```json
{
  "autoContinue": "prompt-async",
  "autoContinueSubagents": "prepare-only",
  "autoContinueSelectTuiForSubagents": false
}
```

Reason: a continuation child created for a subagent does not transparently return its result to the original Task-tool call. The orchestrator should remain the source of truth unless the user explicitly opts into separate subagent continuation sessions.

## Verification Workflow

From the plugin repository:

```sh
npm run check
npm run smoke:threshold-prompts
npm run smoke:auto-prepare
npm run smoke:auto-prompt-async
npm run smoke:auto-subagent
npm run smoke
npm run smoke:subagent
```

Expected results:

- `node --check src/plugin.js` succeeds.
- `bash -n scripts/install.sh` succeeds if installer validation is included in `npm run check`.
- `bash -n scripts/subagent-smoke.sh` succeeds if subagent smoke validation is included in `npm run check`.
- `npm run smoke:threshold-prompts` validates procedural reflection prompt injection, once semantics, no accidental auto-continue, subagent targeting, and invalid prompt handling.
- `npm run smoke:auto-prepare`, `npm run smoke:auto-prompt-async`, and `npm run smoke:auto-subagent` validate auto-continue modes with deterministic mocks.
- `npm run smoke` runs OpenCode from `test-fixture/`.
- The top-level smoke test should produce a context-governor handoff message because test thresholds are tiny.
- `npm run smoke:subagent` runs OpenCode from `test-fixture-subagent/` using a deterministic command marked `agent: general` and `subtask: true`; it should observe at least two session IDs in `.context-governor.log` and output `SUBAGENT_CONTEXT_GOVERNOR_HANDOFF`.

From a target project after installation:

```sh
opencode run 'Say hello. If context governor gives instructions, follow them.'
```

If the project uses production thresholds, this may only show normal model output. To force a quick test, temporarily set the project's plugin options to:

```json
{
  "informThreshold": 1,
  "warnThreshold": 5,
  "handoffThreshold": 10,
  "reserveOutputTokens": 0,
  "log": true
}
```

Then rerun OpenCode and inspect `.context-governor.log` in the project root.

## Troubleshooting

1. Plugin does not seem to load.
   - Confirm `.opencode/opencode.json` is in the project root where OpenCode is run.
   - Confirm the plugin path is absolute and points to an existing `plugin.js`.
   - Enable `log: true` and rerun OpenCode.
   - Check for `.context-governor.log` in the project root.

2. Handoff never triggers.
   - Lower thresholds temporarily to the test preset.
   - Confirm `noteMode` is `always` or `handoff`.
   - Confirm `enabled` is not `false`.
   - Remember that production thresholds may require a large context before triggering.
   - Confirm the assistant response includes the configured marker, default `CONTEXT_GOVERNOR_HANDOFF`, when auto-continue is expected.

3. Procedural reflection prompt never appears.
   - Confirm `thresholdPrompts` is an array and each entry has a numeric `threshold` and non-empty `prompt`.
   - Lower the prompt threshold temporarily to `0` for a deterministic test.
   - Confirm `appliesTo` matches the session kind: `all`, `orchestrator`, `subagent`, or `continuation-child`.
   - Remember `once` defaults to `true`, so a prompt should appear only once per session.

4. Handoff triggers too early.
   - Increase `informThreshold`, `warnThreshold`, and `handoffThreshold`.
   - Increase `estimateCharsPerToken` slightly if estimates are too conservative.
   - Increase `reserveOutputTokens` only if you want more completion headroom, not later handoff.

5. Existing OpenCode config was modified incorrectly.
   - Restore from `opencode.json.bak.<timestamp>` created by the installer.
   - Reapply the plugin entry manually, preserving unrelated OpenCode settings.

6. Curl installer points to the wrong repository.
   - Use `OPENCODE_CONTEXT_GOVERNOR_RAW_BASE` for forks.
   - Use `OPENCODE_CONTEXT_GOVERNOR_PLUGIN_URL` for a direct plugin URL.

## Agent Behavior Guidelines

When using this skill as an agent:

1. Inspect the target project path before editing config.
2. Back up `.opencode/opencode.json` before manual edits.
3. Preserve all existing OpenCode config keys and plugin entries.
4. Prefer the guided installer for normal user setup.
5. Prefer manual config for local development, tests, or when the repository has not been pushed to GitHub yet.
6. Use low thresholds for smoke tests, then restore production or user-selected thresholds.
7. When configuring `thresholdPrompts`, prefer procedural reflection over generic task planning: ask the agent to review procedure, skills, instructions, task decomposition, tests, handoff conventions, and durable learnings.
8. Never preserve credentials, API keys, tokens, or passwords in handoff instructions, reflection prompts, or logs. Redact secrets as `[REDACTED]`.
9. Verify with `npm run check` in the plugin repo and an `opencode run` smoke test in the target project when feasible.

## Common Pitfalls

1. Using the curl installer before the GitHub repository exists or is pushed.
   - The raw GitHub URL only works after the repository and branch are available remotely.

2. Forgetting that this is not exact token accounting.
   - Leave margin. Operational reliability matters more than exactness.

3. Permanently leaving test thresholds enabled.
   - Test thresholds force immediate handoff and are not suitable for normal work.

4. Overwriting `.opencode/opencode.json`.
   - Always merge the plugin entry into existing config.

5. Writing logs into `.opencode/`.
   - The plugin writes `.context-governor.log` in the project root when `log` is enabled.

## Verification Checklist

- [ ] `src/plugin.js` exists and passes syntax check.
- [ ] `scripts/install.sh` exists, is executable, and passes `bash -n`.
- [ ] README includes curl installer and manual config examples.
- [ ] Skill and README examples include current options for `autoContinue`, `autoContinueSubagents`, and `thresholdPrompts` when relevant.
- [ ] Target project has `.opencode/opencode.json` with the plugin entry.
- [ ] Existing OpenCode config was preserved or backed up.
- [ ] Smoke test passes or debug log confirms plugin load.
- [ ] `npm run smoke:threshold-prompts` passes when reflection prompt behavior changed.
- [ ] Production thresholds are restored after low-threshold testing.
