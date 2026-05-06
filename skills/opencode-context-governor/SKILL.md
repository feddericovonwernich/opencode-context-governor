---
name: opencode-context-governor
description: Use when installing, configuring, testing, or troubleshooting the OpenCode Context Governor plugin in a project. Guides agents through curl installer usage, manual .opencode/opencode.json setup, threshold selection, and verification.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [opencode, plugin, context-window, tokens, handoff, installer]
    related_skills: [opencode]
---

# OpenCode Context Governor

## Overview

OpenCode Context Governor is a plugin-only context-budget guard for OpenCode. It makes the model aware of approximate context-window usage and can force a handoff once a configurable token threshold is crossed.

Use this skill when an agent needs to install the plugin into a project, configure `.opencode/opencode.json`, choose sane token thresholds, run a low-threshold smoke test, or troubleshoot whether OpenCode loaded the plugin.

The plugin intentionally avoids forking OpenCode. It uses supported OpenCode plugin hooks and conservative token estimates. Exact preflight provider request token counts are not available through plugin hooks, so thresholds should leave safety margin.

## When to Use

Use this skill when:

- The user asks to install OpenCode Context Governor in a project.
- The user asks to configure OpenCode to become context-window aware.
- The user wants agents to hand off automatically near a context limit.
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
  src/plugin.js
  skills/opencode-context-governor/SKILL.md
  test-fixture/.opencode/opencode.json
```

Key files:

- `src/plugin.js`: the OpenCode plugin.
- `scripts/install.sh`: guided installer for end users.
- `README.md`: human-facing installation and configuration instructions.
- `test-fixture/.opencode/opencode.json`: low-threshold fixture for smoke testing.

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
        "log": false,
        "handoffInstruction": "Write a handoff letter and stop. Include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps."
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

## Verification Workflow

From the plugin repository:

```sh
npm run check
npm run smoke
```

Expected results:

- `node --check src/plugin.js` succeeds.
- `bash -n scripts/install.sh` succeeds if installer validation is included in `npm run check`.
- `npm run smoke` runs OpenCode from `test-fixture/`.
- The smoke test should produce a context-governor handoff message because test thresholds are tiny.

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

3. Handoff triggers too early.
   - Increase `informThreshold`, `warnThreshold`, and `handoffThreshold`.
   - Increase `estimateCharsPerToken` slightly if estimates are too conservative.
   - Increase `reserveOutputTokens` only if you want more completion headroom, not later handoff.

4. Existing OpenCode config was modified incorrectly.
   - Restore from `opencode.json.bak.<timestamp>` created by the installer.
   - Reapply the plugin entry manually, preserving unrelated OpenCode settings.

5. Curl installer points to the wrong repository.
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
7. Never preserve credentials, API keys, tokens, or passwords in handoff instructions or logs. Redact secrets as `[REDACTED]`.
8. Verify with `npm run check` in the plugin repo and an `opencode run` smoke test in the target project when feasible.

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
- [ ] Target project has `.opencode/opencode.json` with the plugin entry.
- [ ] Existing OpenCode config was preserved or backed up.
- [ ] Smoke test passes or debug log confirms plugin load.
- [ ] Production thresholds are restored after low-threshold testing.
