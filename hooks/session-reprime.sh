#!/usr/bin/env bash
# Claude Code SessionStart (startup|clear|compact): re-prime a bound story
# session. It prints the role card, the file paths, the role's state (at most
# 3,000 characters) and the protocol line. An unbound session gets nothing.
# Plain stdout reaches the model on SessionStart (code.claude.com/docs/en/hooks,
# as of 2026-10-27). Hook context is summarized away by a compaction, so this
# runs again after each one.
# Replaces plan-context.sh, which named the newest plan of the main checkout
# to every session, also to a worktree session of another story.
# Informational: never blocks, always exits 0.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

input="$(cat)"
src="$(jq -r '.source // empty' <<<"${input}" 2>/dev/null)"
case "${src}" in
  startup|clear|compact|"") ;;
  *) exit 0 ;;
esac

b="$(story_binding "${input}")"
[ -n "${b}" ] || exit 0
dir="$(story_plans_dir)" || exit 0
role="$(story_field "${b}" role)"
slug="$(story_field "${b}" slug)"
parent="$(story_field "${b}" parent)"
state="${dir}/${slug}.d/${role}.md"

story_card "${role}" "${slug}" "${parent}"
printf 'Plan: %s/%s.md\n' "${dir}" "${slug}"
printf 'Ledger: %s/%s.d/ledger.md\n' "${dir}" "${slug}"
printf 'State: %s\n' "${state}"
if [ -f "${state}" ]; then
  printf '\nYour saved state (%s):\n' "$(date -r "${state}" -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"
  head -c 3000 "${state}"
  printf '\n'
else
  printf 'No saved state yet.\n'
fi
[ "${role}" = orchestrator ] || story_protocol_line
exit 0
