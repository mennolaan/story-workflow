#!/usr/bin/env bash
# Claude Code PostToolUse on Edit|Write|Bash: print the compaction reminder
# once per session per plan, at the moment a plan under .plans/ gains its
# "## Review" section. That section is what marks the plan phase finished
# (CLAUDE.md "Stories and features" step 3).
# Why PostToolUse and not FileChanged: the FileChanged matcher is a literal
# filename watch list over a letters, digits and underscore charset
# (code.claude.com/docs/en/hooks, verified 2026-08-21), and plan files carry
# one hyphenated name per story, so a ".plans/*.md" watch is not expressible
# there. Edit and Write name their file. A Bash call (heredoc, sed, python)
# names none, so the plan files not older than the lint-mark stamp are the
# candidates (lint-mark.sh writes that stamp on every Bash, Edit and Write).
# Measured 2026-08-21 on session 8dd00593: the context ran from about 300k to
# 671k tokens across the plan-to-implementation boundary, and the 155-call
# build phase then re-read all of it on every call. One /compact at this point
# was worth about 23 percent of that session.
# The hook is informational. It never blocks and it always exits 0.
# Without .claude/story.json it prints nothing (story_enabled).
set -uo pipefail

note() {  # note <text>; renders in the transcript for the user
  jq -cn --arg m "$1" '{systemMessage:$m}'
  exit 0
}

root="${CLAUDE_PROJECT_DIR:-.}"
cd "${root}" 2>/dev/null || note "plan-boundary hook: the directory '${root}' is unreadable. The compaction reminder stays off until you correct CLAUDE_PROJECT_DIR."

input="$(cat)"
# A bound story session compacts through the context rule (context-guard.sh
# and the context-keeper mod), so this reminder stays silent there.
# shellcheck source=story-lib.sh
. "$(dirname "$0")/story-lib.sh"
story_enabled || exit 0
[ -n "$(story_binding "${input}")" ] && exit 0
tool="$(jq -r '.tool_name // empty' <<<"${input}" 2>/dev/null)"
file="$(jq -r '.tool_input.file_path // empty' <<<"${input}" 2>/dev/null)"
sid="$(jq -r '.session_id // empty' <<<"${input}" 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
plans="$(story_plans_dir)" || plans=".plans"
[ -d "${plans}" ] || exit 0

cands=""
case "${tool}" in
  Edit|Write)
    case "${file}" in
      */.plans/*.md|.plans/*.md) cands="${file}" ;;
    esac
    ;;
  Bash)
    mark="${TMPDIR:-/tmp}/claude-lint-mark-${sid:-default}"
    if [ -f "${mark}" ]; then
      cands="$(find "${plans}" -name '*.md' -type f -newer "${mark}" 2>/dev/null)"
    else
      cands="$(find "${plans}" -name '*.md' -type f 2>/dev/null)"
    fi
    ;;
esac
[ -n "${cands}" ] || exit 0

while IFS= read -r f; do
  [ -n "${f}" ] && [ -f "${f}" ] || continue
  grep -q '^## Review' "${f}" 2>/dev/null || continue
  key="$(printf '%s' "${f}" | tr -cd 'A-Za-z0-9')"
  seen="${TMPDIR:-/tmp}/claude-plan-boundary-${sid:-default}-${key}"
  [ -e "${seen}" ] && continue
  : > "${seen}" 2>/dev/null || true
  note "Plan boundary: ${f} now carries its Review section, so the plan phase is complete. Run /compact before implementation starts. This keeps the build phase off the planning context. The same step was worth about 23 percent of the tokens in the 2026-08-20 session."
done <<<"${cands}"
exit 0
