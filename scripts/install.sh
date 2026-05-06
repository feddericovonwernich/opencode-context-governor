#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="${OPENCODE_CONTEXT_GOVERNOR_RAW_BASE:-https://raw.githubusercontent.com/feddericovonwernich/opencode-context-governor/main}"
PLUGIN_URL="${OPENCODE_CONTEXT_GOVERNOR_PLUGIN_URL:-$RAW_BASE/src/plugin.js}"
INSTALL_DIR="${OPENCODE_CONTEXT_GOVERNOR_HOME:-$HOME/.local/share/opencode-context-governor}"
PLUGIN_PATH="$INSTALL_DIR/plugin.js"
PROJECT_DIR="${1:-$PWD}"
CONFIG_PATH="$PROJECT_DIR/.opencode/opencode.json"

say() {
  printf '%s\n' "$*"
}

have_tty=false
if [ -r /dev/tty ]; then
  exec 3</dev/tty
  have_tty=true
fi

prompt() {
  local name="$1"
  local question="$2"
  local default="$3"
  local value=""

  if [ "$have_tty" = true ]; then
    printf '%s [%s]: ' "$question" "$default" > /dev/tty
    IFS= read -r value <&3 || value=""
  fi

  if [ -z "$value" ]; then
    value="$default"
  fi

  printf -v "$name" '%s' "$value"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    say "Missing required command: $cmd"
    say "Install $cmd and run this installer again."
    exit 1
  fi
}

say "OpenCode Context Governor installer"
say ""
say "Project: $PROJECT_DIR"
say "Config:  $CONFIG_PATH"
say "Plugin:  $PLUGIN_PATH"
say ""

require_command curl
require_command node

mkdir -p "$INSTALL_DIR"
say "Downloading plugin from: $PLUGIN_URL"
curl -fsSL "$PLUGIN_URL" -o "$PLUGIN_PATH"
chmod 0644 "$PLUGIN_PATH"

say ""
say "Choose context thresholds. Use tiny values only for testing."
prompt preset "Preset: production, conservative, or test" "production"

case "$preset" in
  production)
    default_inform=120000
    default_warn=140000
    default_handoff=150000
    default_reserve=12000
    ;;
  conservative)
    default_inform=90000
    default_warn=110000
    default_handoff=125000
    default_reserve=16000
    ;;
  test)
    default_inform=1
    default_warn=5
    default_handoff=10
    default_reserve=0
    ;;
  *)
    say "Unknown preset '$preset'; using production defaults."
    default_inform=120000
    default_warn=140000
    default_handoff=150000
    default_reserve=12000
    ;;
esac

prompt inform "Inform threshold tokens" "$default_inform"
prompt warn "Warn threshold tokens" "$default_warn"
prompt handoff "Handoff threshold tokens" "$default_handoff"
prompt reserve "Reserved output tokens" "$default_reserve"
prompt estimate "Estimated chars per token; lower is more conservative" "3"
prompt log_enabled "Enable debug log? true/false" "false"
prompt handoff_instruction "Handoff instruction" "Write a handoff letter and stop. Include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps."

mkdir -p "$(dirname "$CONFIG_PATH")"
if [ -f "$CONFIG_PATH" ]; then
  backup="$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$backup"
  say "Backed up existing config to: $backup"
fi

PLUGIN_PATH="$PLUGIN_PATH" \
CONFIG_PATH="$CONFIG_PATH" \
INFORM="$inform" \
WARN="$warn" \
HANDOFF="$handoff" \
RESERVE="$reserve" \
ESTIMATE="$estimate" \
LOG_ENABLED="$log_enabled" \
HANDOFF_INSTRUCTION="$handoff_instruction" \
node <<'NODE'
const fs = require("fs")
const path = process.env.CONFIG_PATH
const pluginPath = process.env.PLUGIN_PATH

function numberFromEnv(name) {
  const value = Number(process.env[name])
  if (!Number.isFinite(value)) {
    throw new Error(`${name} must be a number`)
  }
  return value
}

function boolFromEnv(name) {
  const value = String(process.env[name] || "").toLowerCase()
  if (value === "true") return true
  if (value === "false") return false
  throw new Error(`${name} must be true or false`)
}

let config = {}
if (fs.existsSync(path)) {
  const raw = fs.readFileSync(path, "utf8").trim()
  if (raw) config = JSON.parse(raw)
}

if (!Array.isArray(config.plugin)) config.plugin = []

const options = {
  enabled: true,
  informThreshold: numberFromEnv("INFORM"),
  warnThreshold: numberFromEnv("WARN"),
  handoffThreshold: numberFromEnv("HANDOFF"),
  reserveOutputTokens: numberFromEnv("RESERVE"),
  estimateCharsPerToken: numberFromEnv("ESTIMATE"),
  noteMode: "always",
  appendToolWarnings: true,
  mutateUserMessageAtHandoff: true,
  log: boolFromEnv("LOG_ENABLED"),
  handoffInstruction: process.env.HANDOFF_INSTRUCTION,
}

config.plugin = config.plugin.filter((entry) => {
  if (typeof entry === "string") return entry !== pluginPath && !entry.includes("opencode-context-governor")
  if (Array.isArray(entry)) {
    const first = entry[0]
    return first !== pluginPath && !(typeof first === "string" && first.includes("opencode-context-governor"))
  }
  return true
})

config.plugin.push([pluginPath, options])
fs.writeFileSync(path, JSON.stringify(config, null, 2) + "\n")
NODE

say ""
say "Installed OpenCode Context Governor."
say "Config updated: $CONFIG_PATH"
say ""
say "Next steps:"
say "  cd $PROJECT_DIR"
say "  opencode run 'Say hello. If context governor gives instructions, follow them.'"
say ""
say "To test handoff quickly, rerun with the test preset:"
say "  curl -fsSL $RAW_BASE/scripts/install.sh | bash -s -- $PROJECT_DIR"
