#!/usr/bin/env bash
# Claude Code PostToolUse (*) and Stop: the save half of the 35% context rule.
# Procedure: skills/story/SKILL.md ("Context rule"), config in
# .claude/skills/story/config.json (checkpointPercent).
#
# The context size is the last main-chain assistant line of the transcript:
# input + cache creation + cache read tokens. The window follows the model id
# (story_window). Under a 400k window the rule is off: silent, no nudge, no
# gate. At or above checkpointPercent of the window, the first time
# is the crossing; .plans/.sessions/<key>.crossed holds its epoch. A
# checkpoint is fresh when it exists, holds 400+ characters and is not older
# than the crossing.
#   PostToolUse: one additionalContext nudge per crossing while it is stale.
#   Stop: one block per crossing while it is stale. stop_hook_active passes.
# Below the threshold the crossing is cleared, so the next one counts again.
# The context-keeper mod (hooks/register.tsx) reads the same
# .crossed file and compacts once the checkpoint is fresh.
# Never fails a tool call: on an unreadable input it exits 0. Without jq it
# exits 0 and, on Stop, prints a fixed systemMessage for the user, because
# nobody sees stderr from a hook that exits 0 (code.claude.com/docs/en/hooks,
# as of 2026-10-27).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

input="$(cat)"
if ! command -v jq >/dev/null 2>&1; then
  if grep -Eq '"hook_event_name"[[:space:]]*:[[:space:]]*"Stop"' <<<"${input}"; then
    printf '%s\n' '{"systemMessage":"context-guard: jq is not on PATH, so the 35% save rule does not run. Install it (brew install jq)."}'
  fi
  exit 0
fi

event="$(jq -r '.hook_event_name // empty' <<<"${input}" 2>/dev/null)"
case "${event}" in PostToolUse|Stop) ;; *) exit 0 ;; esac
transcript="$(jq -r '.transcript_path // empty' <<<"${input}" 2>/dev/null)"
read -r tokens model <<<"$(story_usage "${transcript}")"
[ -n "${tokens:-}" ] || exit 0

dir="$(story_plans_dir)" || exit 0
key="$(story_key "${input}")"
[ -n "${key}" ] || exit 0
mark="${dir}/.sessions/${key}"
window="$(story_window "${model:-unknown}")"
# NOTE(eiffel): the same floor as MIN_WINDOW in the context-keeper mod. A session in
# this repo starts near 100k tokens, so under a 400k window no compaction gets below
# the save point and the rule would nudge and gate after every compaction.
[ "${window}" -ge 400000 ] || exit 0
pct="$(story_config checkpointPercent 35)"
limit=$(( window * pct / 100 ))
now_pct=$(( tokens * 100 / window ))

if [ "${tokens}" -lt "${limit}" ]; then
  rm -f "${mark}.crossed" "${mark}.nudged" "${mark}.blocked" 2>/dev/null
  exit 0
fi

mkdir -p "${dir}/.sessions" 2>/dev/null || exit 0
crossed="$(cat "${mark}.crossed" 2>/dev/null)"
if [ -z "${crossed}" ]; then
  crossed="$(date +%s)"
  printf '%s\n' "${crossed}" >"${mark}.crossed"
fi
state="$(story_state_file "${input}")"
story_is_fresh "${state}" "${crossed}" && exit 0

case "${event}" in
  PostToolUse)
    [ "$(cat "${mark}.nudged" 2>/dev/null)" = "${crossed}" ] && exit 0
    printf '%s\n' "${crossed}" >"${mark}.nudged"
    jq -cn --arg c "Context ${now_pct}% (${tokens} of ${window} tokens), at or above the ${pct}% save point. At the next safe moment (a finished step, never mid-edit or mid-gate) run /checkpoint. It writes ${state}." \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
    ;;
  Stop)
    [ "$(jq -r '.stop_hook_active // false' <<<"${input}" 2>/dev/null)" = true ] && exit 0
    [ "$(cat "${mark}.blocked" 2>/dev/null)" = "${crossed}" ] && exit 0
    printf '%s\n' "${crossed}" >"${mark}.blocked"
    jq -cn --arg r "Context ${now_pct}% (${tokens} of ${window} tokens) and no fresh checkpoint at ${state}. Run /checkpoint now, then end the turn as you planned." \
      '{decision:"block",reason:$r}'
    ;;
esac
exit 0
