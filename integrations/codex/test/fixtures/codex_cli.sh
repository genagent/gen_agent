#!/bin/sh
set -eu

fixture_dir=$(cd "$(dirname "$0")" && pwd)

mode=fresh
if [ "${2:-}" = "resume" ]; then
  mode=resume
fi

printf '%s\n' "$@" > "$fixture_dir/$mode.args"
printf '%s\n' "${GEN_AGENT_FIXTURE-unset}" > "$fixture_dir/$mode.env"

case "${*}" in
  *typed-fail*)
    fixture_mode=typed_failure
    ;;
  *fail*)
    fixture_mode=failure
    ;;
  *hold*)
    fixture_mode=hold
    ;;
  *)
    fixture_mode=success
    ;;
esac

case "$fixture_mode" in
  typed_failure)
    printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}'
    printf '%s\n' '{"type":"turn.failed","error":{"code":"fixture_error","message":"typed fixture failure"}}'
    ;;

  failure)
    printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}'
    printf '%s\n' '{"type":"turn.failed","error":"fixture failure"}'
    ;;

  hold)
    printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}'
    sleep 2
    printf '%s\n' '{"type":"turn.completed"}' 2>/dev/null || true
    ;;

  success)
    printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}'
    printf '%s\n' '{"type":"turn.started"}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"mcp_tool_call","id":"call-1","server":"fixture","tool":"read","arguments":{"path":"README.md"},"result":{"content":[]},"status":"completed"}}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution","id":"cmd-1","command":"pwd","aggregated_output":"/fixture","status":"completed"}}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"file_change","id":"file-1","changes":[],"status":"completed"}}'
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"fixture-%s"}}\n' "$mode"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":2}}'
    ;;

  *)
    printf 'unexpected fixture mode: %s\n' "$fixture_mode" >&2
    exit 2
    ;;
esac
