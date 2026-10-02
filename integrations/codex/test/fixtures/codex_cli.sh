#!/bin/sh
set -eu

fixture_dir=$(cd "$(dirname "$0")" && pwd)
corpus="$fixture_dir/codex/0.157.1"
mode=fresh
if [ "${2:-}" = "resume" ]; then
  mode=resume
fi

printf '%s\n' "$@" > "$fixture_dir/$mode.args"
printf '%s\n' "${GEN_AGENT_FIXTURE-unset}" > "$fixture_dir/$mode.env"

# Explicit selection uses the final prompt argument: replay:<manifest scenario>.
for prompt do :; done
hold=false
case "$prompt" in
  replay:*) recording=${prompt#replay:} ;;
  hold) recording=success; hold=true ;;
  *) if [ "$mode" = resume ]; then recording=resume-followup; else recording=resume-initial; fi ;;
esac

# Read the recorded status without requiring another runtime or maintaining a second manifest.
exit_status=$(awk -v scenario="\"$recording\":" '
  index($0, scenario) { selected = 1 }
  selected && /"exit_status":/ { gsub(/[^0-9]/, ""); print; exit }
' "$corpus/manifest.json")
if [ -z "$exit_status" ] || [ ! -f "$corpus/$recording.jsonl" ]; then
  printf 'unknown recording: %s\n' "$recording" >&2
  exit 2
fi

# Cancellation tests pause before the terminal line, preserving the recorded prefix.
if [ "$hold" = true ]; then
  sed '$d' "$corpus/$recording.jsonl"
  sleep 2
  tail -n 1 "$corpus/$recording.jsonl" 2>/dev/null || true
else
  cat "$corpus/$recording.jsonl"
fi
exit "$exit_status"
