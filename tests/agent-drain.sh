#!/usr/bin/env bash
# What the agent does after a teardown, while a purge is still on its way.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
good() { echo "  PASS  $1"; P=$((P+1)); }
bad()  { echo "  FAIL  $1"; F=$((F+1)); }

# The decision, lifted out of the loop it lives in. Everything else in that loop
# talks to the platform; this is the part that decides whether to walk away.
ok() { LAST="$*"; }
info() { LAST="$*"; }

drain_decision() {
  local interactive=$1
  if [[ -n "$AGENT_STOP_REASON" ]]; then
    if [[ "$COMMANDS_EXECUTED" -gt 0 ]]; then
      AGENT_QUIET_SINCE=$SECONDS_NOW
    elif [[ -z "${AGENT_QUIET_SINCE:-}" ]]; then
      AGENT_QUIET_SINCE=$SECONDS_NOW
    elif (( SECONDS_NOW - AGENT_QUIET_SINCE >= AGENT_DRAIN_SECONDS )); then
      if [[ "$interactive" == "yes" ]]; then
        ok "$AGENT_STOP_REASON done; nothing left to watch on this host"
        return 1
      fi
      info "$AGENT_STOP_REASON done; waiting for the next instance"
      AGENT_STOP_REASON=""
      AGENT_QUIET_SINCE=""
    fi
  else
    AGENT_QUIET_SINCE=""
  fi
  return 0
}

AGENT_DRAIN_SECONDS=60

echo "a teardown does not send the agent home before the purge arrives"
AGENT_STOP_REASON="teardown"; AGENT_QUIET_SINCE=""; COMMANDS_EXECUTED=1; SECONDS_NOW=0
drain_decision yes && good "stays on the pass that ran the teardown" || bad "left immediately"

# The console queues the destroy behind the terminate at human speed. Three
# seconds of silence used to be enough to lose it.
COMMANDS_EXECUTED=0; SECONDS_NOW=3
drain_decision yes && good "stays three seconds later" || bad "left after one quiet pass"

COMMANDS_EXECUTED=0; SECONDS_NOW=20
drain_decision yes && good "and twenty seconds later" || bad "left before the purge could arrive"

# The purge lands, and the clock starts again from there.
COMMANDS_EXECUTED=1; SECONDS_NOW=25
drain_decision yes && good "stays on the pass that ran the purge" || bad "left while working"
[ "$AGENT_QUIET_SINCE" = "25" ] && good "and the quiet clock restarts" || bad "clock is $AGENT_QUIET_SINCE"

echo
echo "but it does leave once the host is genuinely finished"
COMMANDS_EXECUTED=0; SECONDS_NOW=30
drain_decision yes && good "not yet" || bad "left too early"
COMMANDS_EXECUTED=0; SECONDS_NOW=86
drain_decision yes && bad "still hanging around" || good "leaves after a quiet minute"
[[ "$LAST" == *"nothing left to watch"* ]] && good "and says so" || bad "said '$LAST'"

echo
echo "run as a service it waits for the next instance instead of leaving"
AGENT_STOP_REASON="purge"; AGENT_QUIET_SINCE=""; COMMANDS_EXECUTED=0; SECONDS_NOW=0
drain_decision no >/dev/null
COMMANDS_EXECUTED=0; SECONDS_NOW=90
drain_decision no && good "stays up" || bad "a service walked out"
[ -z "$AGENT_STOP_REASON" ] && good "and is ready for the next one" || bad "still holding '$AGENT_STOP_REASON'"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
