#!/bin/sh
set -eu

fixture_dir=$(cd "$(dirname "$0")" && pwd)
mode=fresh
for arg in "$@"; do
  if [ "$arg" = "--resume" ]; then mode=resume; fi
done
printf '%s\n' "$@" > "$fixture_dir/$mode.args"
pwd > "$fixture_dir/$mode.cwd"
printf '%s\n' "${GEN_AGENT_FIXTURE-unset}" > "$fixture_dir/$mode.env"

case "$*" in
  *fail*)
    printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"fixture failure","session_id":"fixture-session","usage":{"input_tokens":2,"output_tokens":1}}'
    ;;
  *truncated*)
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}'
    exit 1
    ;;
  *hold*)
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"waiting"}}}'
    printf '%s\n' '{"type":"system","subtype":"heartbeat"}'
    sleep 2
    printf '%s\n' '{"type":"result","result":"done","session_id":"fixture-session"}' 2>/dev/null || true
    ;;
  *)
    printf '%s\n' '{"type":"system","subtype":"init"}'
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fixture-"}}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"fixture-reply"},{"type":"tool_use","id":"call-1","name":"mcp__fixture__read","input":{"path":"README.md"}}]}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":"contents","is_error":false}]}}'
    printf '%s\n' '{"type":"result","result":"fixture-reply","session_id":"fixture-session","total_cost_usd":0.001,"usage":{"input_tokens":3,"output_tokens":2}}'
    ;;
esac
