#!/bin/bash
# Starts Claude Code Remote Control in server mode inside tmux and keeps the
# container alive as long as that tmux session lives. If it exits, the pod
# restarts (restartPolicy) and resumes from the PVC.
set -euo pipefail

WORKDIR="${AGENT_WORKDIR:-/home/agent/work/repo}"
NAME="${AGENT_NAME:-${HOSTNAME}}"
CAPACITY="${RC_CAPACITY:-4}"

# Git identity + credential helper. (Claude itself is denied `git config --global`
# by managed settings; this runs before Claude starts.)
git config --global credential.helper /opt/agent/git-credential-file.sh 2>/dev/null || true
git config --global user.name  "${GIT_AUTHOR_NAME:-claude-agent}" 2>/dev/null || true
git config --global user.email "${GIT_AUTHOR_EMAIL:-claude-agent@users.noreply.github.com}" 2>/dev/null || true

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# tmux provides the TTY that `claude remote-control` needs for the one-time
# workspace-trust prompt. Attach with: kubectl exec -it <pod> -- tmux attach -t rc
tmux new-session -d -s rc -c "$WORKDIR" \
  "claude remote-control --name '${NAME}' --spawn worktree --capacity ${CAPACITY}; echo 'remote-control exited'; sleep 5"

echo "{\"audit\":\"agent-start\",\"pod\":\"${HOSTNAME}\",\"workdir\":\"${WORKDIR}\"}"
while tmux has-session -t rc 2>/dev/null; do sleep 15; done
echo "{\"audit\":\"agent-stop\",\"pod\":\"${HOSTNAME}\"}"
exit 1
