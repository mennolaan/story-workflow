#!/usr/bin/env bash
# Claude Code PreToolUse on Bash|Edit|Write: stamp the moment a tool call starts,
# so plan-boundary.sh can tell which files that call touched (files not older
# than the stamp) instead of scanning every plan file on every call.
# One stamp per session; never blocks (exit 0 always).
set -u
input="$(cat)"
sid="$(jq -r '.session_id // empty' <<<"${input}" 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
touch "${TMPDIR:-/tmp}/claude-lint-mark-${sid:-default}" 2>/dev/null || true
exit 0
