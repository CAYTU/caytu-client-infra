#!/usr/bin/env bash
# The signalling token lives in the env file. The tokens file is written from
# it, because two copies kept in step by a human is a drift waiting to happen.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
ok()   { echo "  PASS  $1"; P=$((P+1)); }
bad()  { echo "  FAIL  $1"; F=$((F+1)); }
has()  { case "$2" in *"$1"*) ok "$3";; *) bad "$3 (got: $(head -c 90 <<<"$2"))";; esac; }
hasnt(){ case "$2" in *"$1"*) bad "$3";; *) ok "$3";; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/secrets"
cp compose/secrets/signaling-tokens.example.json "$TMP/secrets/"

COMPOSE_DIR="$TMP"
env_file_for() { printf '%s/.env.test' "$COMPOSE_DIR"; }
env_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
warn() { :; }
eval "$(sed -n '/^seed_signaling_tokens()/,/^}/p' scripts/caytu-client)"

DST="$TMP/secrets/signaling-tokens.json"

echo "a real token is written into the file"
printf 'SIGNALING_AUTH_TOKEN=abc123realtoken\n' > "$TMP/.env.test"
seed_signaling_tokens
has "abc123realtoken" "$(cat "$DST")" "the token from the env file is in it"
hasnt "REPLACE_WITH" "$(cat "$DST")" "no placeholder left behind"

# uid 1001 inside the container has to open a file the deploy user wrote.
[ "$(stat -c %a "$DST")" = "644" ] && ok "readable by the container user" || bad "mode is $(stat -c %a "$DST"), signaling exits on EACCES"

echo
echo "running twice does not rewrite it"
before="$(stat -c %Y "$DST")"; sleep 1; seed_signaling_tokens
[ "$(stat -c %Y "$DST")" = "$before" ] && ok "left alone when already correct" || bad "rewritten needlessly"

echo
echo "a changed token is picked up"
printf 'SIGNALING_AUTH_TOKEN=newtoken456\n' > "$TMP/.env.test"
seed_signaling_tokens
has "newtoken456" "$(cat "$DST")" "the new token is written"
hasnt "abc123realtoken" "$(cat "$DST")" "the old one is gone"

echo
echo "no token means the operator's file is not touched"
rm -f "$DST"; printf '# nothing here\n' > "$TMP/.env.test"
seed_signaling_tokens
has "REPLACE_WITH" "$(cat "$DST")" "falls back to the template"
printf 'hand written\n' > "$DST"; seed_signaling_tokens
has "hand written" "$(cat "$DST")" "an existing file is left alone"

# A file from before this was fixed is on disk owner-only and stays that way
# until something widens it, which no later `up` would otherwise do.
chmod 600 "$DST"; seed_signaling_tokens
[ "$(stat -c %a "$DST")" = "644" ] && ok "an owner-only file is widened" || bad "left at $(stat -c %a "$DST")"

printf '\n  %d passed, %d failed\n' "$P" "$F"; [ "$F" -eq 0 ]
