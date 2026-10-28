#!/usr/bin/env bash
# Claude Code PreCompact: the safety net before a compaction. It copies the
# session's state file to the compact/ folder and appends one line to
# compact/log.tsv: UTC time, trigger, tokens, whether the checkpoint was
# fresh, and the session key.
# It never blocks a compaction: it prints nothing and always exits 0. A
# blocked compaction at the backstop leaves a session that cannot continue.
# Each failed step appends one line to <plans>/.sessions/<key>.log, the file
# the context-keeper mod logs to. Without .claude/story.json it does
# nothing (story_enabled).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

{
  input="$(cat)"
  story_enabled || exit 0
  dir="$(story_plans_dir)" || exit 0
  key="$(story_key "${input}")"
  note() { mkdir -p "${dir}/.sessions" && printf '%s pre-compact: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"${dir}/.sessions/${key:-unknown}.log"; }
  out="$(story_compact_dir "${input}")" || { note "no compact folder for this session, so nothing was saved"; exit 0; }
  mkdir -p "${out}" || { note "cannot create ${out}, so the state copy and the log line are missing"; exit 0; }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  trigger="$(jq -r '.trigger // "unknown"' <<<"${input}" 2>/dev/null)"
  transcript="$(jq -r '.transcript_path // empty' <<<"${input}" 2>/dev/null)"
  read -r tokens _ <<<"$(story_usage "${transcript}")"
  state="$(story_state_file "${input}")"
  crossed="$(cat "${dir}/.sessions/${key}.crossed" 2>/dev/null)"
  fresh=no
  story_is_fresh "${state}" "${crossed:-0}" && fresh=yes
  name="$(basename "${state}" .md)"
  if [ -f "${state}" ]; then
    cp "${state}" "${out}/${name}-${stamp}-state.md" || note "cannot copy ${state} to ${out}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${stamp}" "${trigger}" "${tokens:-unknown}" "${fresh}" "${key}" >>"${out}/log.tsv" \
    || note "cannot append to ${out}/log.tsv"
} >/dev/null 2>&1
exit 0
