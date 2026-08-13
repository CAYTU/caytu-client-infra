# shellcheck shell=bash
# Common helpers sourced by caytu-client and its lib scripts. No side effects
# at source time.

# Colors (falls back gracefully in dumb terminals)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  C_RESET="$(tput sgr0)"
  C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_BOLD="$(tput bold)"
else
  C_RESET="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD=""
fi

log()    { printf "%s\n" "$*" >&2; }
info()   { printf "%s%s%s %s\n" "$C_BLUE" "→" "$C_RESET" "$*" >&2; }
ok()     { printf "%s%s%s %s\n" "$C_GREEN" "✓" "$C_RESET" "$*" >&2; }
warn()   { printf "%s%s%s %s\n" "$C_YELLOW" "!" "$C_RESET" "$*" >&2; }
err()    { printf "%s%s%s %s\n" "$C_RED" "✗" "$C_RESET" "$*" >&2; }
die()    { err "$*"; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Parse a value out of a plain KEY=VALUE .env file (no quoting, no comments).
env_get() {
  local file=$1 key=$2
  [[ -f "$file" ]] || return 1
  grep -E "^${key}=" "$file" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# Set KEY=VALUE, replacing an existing line or appending one. Values go through
# the environment rather than into the awk program, so a value containing
# slashes or ampersands cannot corrupt the file. Writes via a temp file so a
# failure mid-write cannot truncate the original.
env_upsert() {
  local file=$1 key=$2 value=$3
  [[ -f "$file" ]] || die "no such env file: $file"
  local tmp; tmp="$(mktemp)"
  # Keep the owner and mode. The agent writes this as root from a container, so
  # a plain mv hands the deploy user's env file to root and locks them out.
  local owner mode
  owner="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"
  mode="$(stat -c '%a' "$file" 2>/dev/null || true)"

  KEY="$key" VALUE="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

  [[ -n "$owner" ]] && chown "$owner" "$tmp" 2>/dev/null || true
  [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

# State: a tiny JSON blob next to the script. We use jq if available, otherwise
# a naive line-based fallback (state keys are always simple strings).
state_get() {
  local key=$1
  [[ -f "$STATE_FILE" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE"
  else
    grep -E "^\"${key}\":" "$STATE_FILE" 2>/dev/null | head -1 | sed -E 's/^"[^"]+": *"?([^",]*)"?,?$/\1/'
  fi
}

state_set() {
  local key=$1 value=$2
  mkdir -p "$(dirname "$STATE_FILE")"
  if command -v jq >/dev/null 2>&1; then
    if [[ -f "$STATE_FILE" ]]; then
      tmp="$(mktemp)"
      jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "$tmp"
      mv "$tmp" "$STATE_FILE"
    else
      jq -n --arg k "$key" --arg v "$value" '{($k): $v}' > "$STATE_FILE"
    fi
  else
    warn "jq not installed — using naive state writer. Install jq for reliability."
    printf '{\n  "%s": "%s"\n}\n' "$key" "$value" > "$STATE_FILE"
  fi
}

# Which docker compose subcommand does this host have?
docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "neither 'docker compose' nor 'docker-compose' is installed"
  fi
}

confirm() {
  local prompt="${1:-continue?}"
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^([yY]|yes|YES)$ ]]
}
