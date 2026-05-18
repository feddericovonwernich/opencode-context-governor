#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SKILL="$REPO_ROOT/skills/opencode-context-governor/SKILL.md"
SKILL_NAME="opencode-context-governor"
DRY_RUN=0
INSTALL_IF_MISSING=1
TARGET_DIR=""
PROJECT_DIR=""
HERMES_HOME_OVERRIDE="${HERMES_HOME:-}"
OPENCODE_HOME_OVERRIDE="${OPENCODE_CONFIG_HOME:-}"
CLAUDE_HOME_OVERRIDE="${CLAUDE_HOME:-}"
AGENTS_HOME_OVERRIDE="${AGENTS_HOME:-}"
HARNESS_SET=0
HARNESSES=()
TMP_FILES=()

usage() {
  cat <<'EOF'
Usage: scripts/update-agent-skill.sh [options]

Install or update this repository's bundled agent skill for one or more agent
harnesses. The canonical source is:

  skills/opencode-context-governor/SKILL.md

By default, the script targets OpenCode's global skill directory:

  ~/.config/opencode/skills/opencode-context-governor/SKILL.md

Options:
  --harness NAME          Harness to update: hermes, opencode, claude, agents,
                          or all. May be repeated. Default: opencode.
  --dry-run               Show what would change without writing files.
  --no-install            If no installed copy is found, exit instead of installing.
  --target-dir PATH       Update/install into this exact skill directory.
                          The script writes PATH/SKILL.md. Only valid with one
                          harness.
  --project-dir PATH      For OpenCode, use PATH/.opencode/skills instead of the
                          global OpenCode skill directory.
  --hermes-home PATH      Search/install Hermes under PATH/skills instead of
                          $HERMES_HOME or ~/.hermes.
  --opencode-home PATH    Search/install OpenCode under PATH/skills instead of
                          $OPENCODE_CONFIG_HOME or ~/.config/opencode.
  --claude-home PATH      Search/install Claude-compatible skills under
                          PATH/skills instead of ~/.claude/skills.
  --agents-home PATH      Search/install agent-compatible skills under
                          PATH/skills instead of ~/.agents/skills.
  -h, --help              Show this help.

Examples:
  scripts/update-agent-skill.sh --dry-run
  scripts/update-agent-skill.sh --harness opencode
  scripts/update-agent-skill.sh --harness opencode --project-dir /path/to/project
  scripts/update-agent-skill.sh --harness hermes --hermes-home ~/.hermes/profiles/wiki-importacion-china
  scripts/update-agent-skill.sh --harness all --dry-run
  scripts/update-agent-skill.sh --harness opencode --target-dir ~/.config/opencode/skills/opencode-context-governor
EOF
}

cleanup() {
  local file
  for file in "${TMP_FILES[@]:-}"; do
    if [ -n "$file" ] && [ -f "$file" ]; then
      rm -f "$file"
    fi
  done
  return 0
}
trap cleanup EXIT

add_harness() {
  local harness="$1"
  case "$harness" in
    hermes|opencode|claude|agents)
      HARNESSES+=("$harness")
      ;;
    all)
      HARNESSES+=("hermes" "opencode" "claude" "agents")
      ;;
    *)
      echo "unknown harness: $harness" >&2
      usage >&2
      exit 2
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -ge 2 ] || { echo "missing value for --harness" >&2; exit 2; }
      HARNESS_SET=1
      add_harness "$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-install)
      INSTALL_IF_MISSING=0
      shift
      ;;
    --target-dir)
      [ "$#" -ge 2 ] || { echo "missing value for --target-dir" >&2; exit 2; }
      TARGET_DIR="$2"
      shift 2
      ;;
    --project-dir)
      [ "$#" -ge 2 ] || { echo "missing value for --project-dir" >&2; exit 2; }
      PROJECT_DIR="$2"
      shift 2
      ;;
    --hermes-home)
      [ "$#" -ge 2 ] || { echo "missing value for --hermes-home" >&2; exit 2; }
      HERMES_HOME_OVERRIDE="$2"
      shift 2
      ;;
    --opencode-home)
      [ "$#" -ge 2 ] || { echo "missing value for --opencode-home" >&2; exit 2; }
      OPENCODE_HOME_OVERRIDE="$2"
      shift 2
      ;;
    --claude-home)
      [ "$#" -ge 2 ] || { echo "missing value for --claude-home" >&2; exit 2; }
      CLAUDE_HOME_OVERRIDE="$2"
      shift 2
      ;;
    --agents-home)
      [ "$#" -ge 2 ] || { echo "missing value for --agents-home" >&2; exit 2; }
      AGENTS_HOME_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$HARNESS_SET" -eq 0 ]; then
  add_harness opencode
fi

if [ -n "$TARGET_DIR" ] && [ "${#HARNESSES[@]}" -ne 1 ]; then
  echo "--target-dir is only valid with exactly one harness" >&2
  exit 2
fi

expand_path() {
  local value="$1"
  if [ "${value#\~/}" != "$value" ]; then
    printf '%s/%s' "$HOME" "${value#\~/}"
  elif [ "$value" = "~" ]; then
    printf '%s' "$HOME"
  else
    printf '%s' "$value"
  fi
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

ensure_source() {
  if [ ! -f "$SOURCE_SKILL" ]; then
    echo "source skill not found: $SOURCE_SKILL" >&2
    exit 1
  fi
}

frontmatter_value() {
  local key="$1"
  grep -E "^${key}:" "$SOURCE_SKILL" | head -n 1 | sed -E "s/^${key}:[[:space:]]*//"
}

write_exported_source_for_harness() {
  local harness="$1"
  local output_file="$2"
  local name description license compatibility
  name="$(frontmatter_value name)"
  description="$(frontmatter_value description)"
  license="$(frontmatter_value license)"
  compatibility="$harness"

  {
    echo "---"
    echo "name: $name"
    echo "description: $description"
    [ -n "$license" ] && echo "license: $license"
    echo "compatibility: $compatibility"
    echo "metadata:"
    echo "  source: opencode-context-governor"
    echo "  source_path: skills/opencode-context-governor/SKILL.md"
    echo "---"
    awk 'BEGIN { n = 0 } /^---[[:space:]]*$/ { n++; if (n == 2) { p = 1; next } } p { print }' "$SOURCE_SKILL"
  } > "$output_file"
}

find_installed_skill_in_root() {
  local skills_root="$1"
  local direct="$skills_root/$SKILL_NAME"

  if [ -f "$direct/SKILL.md" ]; then
    printf '%s\n' "$direct"
    return 0
  fi

  if [ -d "$skills_root" ]; then
    while IFS= read -r candidate; do
      if grep -Eq "^name:[[:space:]]*${SKILL_NAME}[[:space:]]*$" "$candidate"; then
        dirname "$candidate"
        return 0
      fi
    done < <(find "$skills_root" -type f -name SKILL.md 2>/dev/null | sort)
  fi

  return 1
}

skill_roots_for_harness() {
  local harness="$1"
  case "$harness" in
    hermes)
      local hermes_home="${HERMES_HOME_OVERRIDE:-$HOME/.hermes}"
      printf '%s\n' "$(expand_path "$hermes_home")/skills"
      ;;
    opencode)
      if [ -n "$PROJECT_DIR" ]; then
        printf '%s\n' "$(expand_path "$PROJECT_DIR")/.opencode/skills"
      else
        local opencode_home="${OPENCODE_HOME_OVERRIDE:-$HOME/.config/opencode}"
        printf '%s\n' "$(expand_path "$opencode_home")/skills"
      fi
      ;;
    claude)
      local claude_home="${CLAUDE_HOME_OVERRIDE:-$HOME/.claude}"
      printf '%s\n' "$(expand_path "$claude_home")/skills"
      ;;
    agents)
      local agents_home="${AGENTS_HOME_OVERRIDE:-$HOME/.agents}"
      printf '%s\n' "$(expand_path "$agents_home")/skills"
      ;;
  esac
}

copy_skill() {
  local harness="$1"
  local source_file="$2"
  local dest_dir="$3"
  local dest_file="$dest_dir/SKILL.md"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$dest_file" ]; then
      local src_hash dest_hash
      src_hash="$(checksum "$source_file")"
      dest_hash="$(checksum "$dest_file")"
      if [ "$src_hash" = "$dest_hash" ]; then
        echo "dry-run: [$harness] installed skill already up to date: $dest_file"
      else
        echo "dry-run: [$harness] would update $dest_file"
        echo "dry-run: [$harness] would create backup $dest_file.bak.<timestamp>"
      fi
    else
      echo "dry-run: [$harness] would install skill to $dest_file"
    fi
    return 0
  fi

  mkdir -p "$dest_dir"
  if [ -f "$dest_file" ]; then
    local src_hash dest_hash backup
    src_hash="$(checksum "$source_file")"
    dest_hash="$(checksum "$dest_file")"
    if [ "$src_hash" = "$dest_hash" ]; then
      echo "[$harness] installed skill already up to date: $dest_file"
      return 0
    fi
    backup="$dest_file.bak.$(date +%Y%m%d%H%M%S)"
    cp "$dest_file" "$backup"
    echo "[$harness] backup written: $backup"
  fi
  cp "$source_file" "$dest_file"
  echo "[$harness] skill updated: $dest_file"
}

update_harness() {
  local harness="$1"
  local source_file found_dir root install_root roots_text tmp
  if [ "$harness" = "hermes" ]; then
    source_file="$SOURCE_SKILL"
  else
    tmp="$(mktemp "/tmp/${SKILL_NAME}.${harness}.XXXXXX.md")"
    TMP_FILES+=("$tmp")
    write_exported_source_for_harness "$harness" "$tmp"
    source_file="$tmp"
  fi

  if [ -n "$TARGET_DIR" ]; then
    copy_skill "$harness" "$source_file" "$(expand_path "$TARGET_DIR")"
    return 0
  fi

  roots_text="$(skill_roots_for_harness "$harness")"
  while IFS= read -r root; do
    [ -z "$root" ] && continue
    if found_dir="$(find_installed_skill_in_root "$root")"; then
      copy_skill "$harness" "$source_file" "$found_dir"
      return 0
    fi
  done <<< "$roots_text"

  if [ "$INSTALL_IF_MISSING" -eq 0 ]; then
    echo "[$harness] no installed $SKILL_NAME skill found" >&2
    return 1
  fi

  install_root="$(printf '%s\n' "$roots_text" | head -n 1)"
  copy_skill "$harness" "$source_file" "$install_root/$SKILL_NAME"
}

ensure_source

for harness in "${HARNESSES[@]}"; do
  update_harness "$harness"
done
