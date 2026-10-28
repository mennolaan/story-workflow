#!/usr/bin/env bash
# Claude Code PreToolUse on Bash|Edit|Write: stamp the moment a tool call starts,
# so plan-boundary.sh can tell which files that call touched (files not older
# than the stamp) instead of scanning every plan file on every call.
# One stamp per session; never blocks (exit 0 always). Without
# .claude/story.json it writes nothing (story_enabled).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

input="$(cat)"
story_enabled || exit 0
sid="$(jq -r '.session_id // empty' <<<"${input}" 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
touch "${TMPDIR:-/tmp}/claude-lint-mark-${sid:-default}" 2>/dev/null || true
exit 0
