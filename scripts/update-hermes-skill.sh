#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SKILL="$REPO_ROOT/skills/opencode-context-governor/SKILL.md"
SKILL_NAME="opencode-context-governor"
DRY_RUN=0
INSTALL_IF_MISSING=1
TARGET_DIR=""
HERMES_HOME_OVERRIDE="${HERMES_HOME:-}"

usage() {
  cat <<'EOF'
Usage: scripts/update-hermes-skill.sh [options]

Find an installed Hermes skill named opencode-context-governor and update it from
this repository's skills/opencode-context-governor/SKILL.md. If no installed copy
is found, installs it into $HERMES_HOME/skills/opencode-context-governor or
~/.hermes/skills/opencode-context-governor by default.

Options:
  --dry-run              Show what would change without writing files.
  --no-install           If no installed copy is found, exit instead of installing.
  --target-dir PATH      Update/install into this exact skill directory.
                         The script writes PATH/SKILL.md.
  --hermes-home PATH     Search/install under PATH/skills instead of $HERMES_HOME
                         or ~/.hermes.
  -h, --help             Show this help.

Examples:
  scripts/update-hermes-skill.sh --dry-run
  scripts/update-hermes-skill.sh
  scripts/update-hermes-skill.sh --hermes-home ~/.hermes/profiles/wiki-importacion-china
  scripts/update-hermes-skill.sh --target-dir ~/.hermes/skills/opencode-context-governor
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --hermes-home)
      [ "$#" -ge 2 ] || { echo "missing value for --hermes-home" >&2; exit 2; }
      HERMES_HOME_OVERRIDE="$2"
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

find_installed_skill() {
  local hermes_home="$1"
  local skills_root="$hermes_home/skills"
  local direct="$skills_root/$SKILL_NAME"

  if [ -f "$direct/SKILL.md" ]; then
    printf '%s\n' "$direct"
    return 0
  fi

  if [ -d "$skills_root" ]; then
    while IFS= read -r candidate; do
      if grep -Eq '^name:[[:space:]]*opencode-context-governor[[:space:]]*$' "$candidate"; then
        dirname "$candidate"
        return 0
      fi
    done < <(find "$skills_root" -type f -name SKILL.md 2>/dev/null | sort)
  fi

  return 1
}

copy_skill() {
  local dest_dir="$1"
  local dest_file="$dest_dir/SKILL.md"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$dest_file" ]; then
      local src_hash dest_hash
      src_hash="$(checksum "$SOURCE_SKILL")"
      dest_hash="$(checksum "$dest_file")"
      if [ "$src_hash" = "$dest_hash" ]; then
        echo "dry-run: installed skill already up to date: $dest_file"
      else
        echo "dry-run: would update $dest_file"
        echo "dry-run: would create backup $dest_file.bak.<timestamp>"
      fi
    else
      echo "dry-run: would install skill to $dest_file"
    fi
    return 0
  fi

  mkdir -p "$dest_dir"
  if [ -f "$dest_file" ]; then
    local src_hash dest_hash backup
    src_hash="$(checksum "$SOURCE_SKILL")"
    dest_hash="$(checksum "$dest_file")"
    if [ "$src_hash" = "$dest_hash" ]; then
      echo "installed skill already up to date: $dest_file"
      return 0
    fi
    backup="$dest_file.bak.$(date +%Y%m%d%H%M%S)"
    cp "$dest_file" "$backup"
    echo "backup written: $backup"
  fi
  cp "$SOURCE_SKILL" "$dest_file"
  echo "skill updated: $dest_file"
}

ensure_source

if [ -n "$TARGET_DIR" ]; then
  copy_skill "$(expand_path "$TARGET_DIR")"
  exit 0
fi

HERMES_HOME_EFFECTIVE="${HERMES_HOME_OVERRIDE:-$HOME/.hermes}"
HERMES_HOME_EFFECTIVE="$(expand_path "$HERMES_HOME_EFFECTIVE")"

if FOUND_DIR="$(find_installed_skill "$HERMES_HOME_EFFECTIVE")"; then
  copy_skill "$FOUND_DIR"
  exit 0
fi

if [ "$INSTALL_IF_MISSING" -eq 0 ]; then
  echo "no installed $SKILL_NAME skill found under $HERMES_HOME_EFFECTIVE/skills" >&2
  exit 1
fi

copy_skill "$HERMES_HOME_EFFECTIVE/skills/$SKILL_NAME"
