#!/usr/bin/env bash
# Claude Code PostCompact: store the compaction summary as an audit trail, in
# compact/<role or key>-<UTC>.md next to the story files (story-lib.sh,
# story_compact_dir). PostCompact has no decision control and adds no context
# (code.claude.com/docs/en/hooks, as of 2026-10-27). Always exits 0 and prints
# nothing. Each failed step appends one line to <plans>/.sessions/<key>.log,
# the file the context-keeper mod logs to.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

{
  input="$(cat)"
  dir="$(story_plans_dir)" || exit 0
  key="$(story_key "${input}")"
  note() { mkdir -p "${dir}/.sessions" && printf '%s post-compact: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"${dir}/.sessions/${key:-unknown}.log"; }
  summary="$(jq -r '.compact_summary // empty' <<<"${input}" 2>/dev/null)"
  [ -n "${summary}" ] || { note "the hook input has no compact_summary, so no summary was saved"; exit 0; }
  out="$(story_compact_dir "${input}")" || { note "no compact folder for this session, so the summary was not saved"; exit 0; }
  mkdir -p "${out}" || { note "cannot create ${out}, so the summary was not saved"; exit 0; }
  name="$(basename "$(story_state_file "${input}")" .md)"
  trigger="$(jq -r '.trigger // "unknown"' <<<"${input}" 2>/dev/null)"
  file="${out}/${name}-$(date -u +%Y%m%dT%H%M%SZ).md"
  printf '# Compaction summary (%s, trigger %s)\n\n%s\n' "${name}" "${trigger}" "${summary}" >"${file}" \
    || note "cannot write ${file}"
} >/dev/null 2>&1
exit 0
