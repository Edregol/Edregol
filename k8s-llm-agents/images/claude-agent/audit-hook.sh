#!/bin/sh
# Managed audit hook: one JSON line per tool call on the container's stdout
# (PID 1's fd), so the cluster log pipeline (Loki, Elastic, ...) keeps an
# audit trail the agent itself cannot edit. Never blocks the tool call.
phase="${1:-pre}"
jq -c --arg phase "$phase" --arg pod "${HOSTNAME:-unknown}" '{
    ts: (now | todate), audit: "claude-tool", phase: $phase, pod: $pod,
    session: .session_id, cwd: .cwd, tool: .tool_name,
    input: (.tool_input | tostring | .[0:4000])
  }' > /proc/1/fd/1 2>/dev/null || true
exit 0
