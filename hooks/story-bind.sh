#!/usr/bin/env bash
# Binds the current session to a story role. Run it from the Bash tool of the
# session to bind, so it inherits CLAUDE_CODE_HOST_SESSION_ID or
# CLAUDE_CODE_SESSION_ID.
#
# Usage:
#   story-bind.sh <role> <slug> [--parent <session id>]
#   story-bind.sh --show    print the binding, or "unbound"
#   story-bind.sh --state   print the checkpoint path of this session
#   story-bind.sh --unbind [<key>]   remove the binding of this session (or of
#                           <key>, a child's session id) and its .crossed,
#                           .nudged and .blocked marks. Safe to run again.
#   story-bind.sh --check   check the repo config and print its path; binds
#                           nothing (step 0 of /story)
# Roles: orchestrator, plan, implement, pr-review.
#
# Writes <plans>/.sessions/<key>.json with role, slug, state, parent, bound_at
# and session_id, and creates <plans>/<slug>.d/. <plans> is the .plans/ folder
# of the main checkout (story-lib.sh). Exit 1 with the reason on bad input.
# Every mode exits 1 when the repo has no .claude/story.json or the file is not
# valid JSON. It is a command, so it fails loud where the automatic hooks stay
# silent.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

fail() { printf 'story-bind: %s\n' "$1" >&2; exit 1; }

config="$(story_config_file)"
example="$(cd "${here}/.." && pwd)/skills/story/story.example.json"
story_enabled || fail "this repo has no ${config}, so the story workflow is off here. To opt in, copy ${example} to ${config}, set the values for this repo and commit it."
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH. Install it (brew install jq)."
err="$(jq -e 'type == "object"' "${config}" 2>&1 >/dev/null)" \
  || fail "${config} is not valid JSON or not an object: ${err:-not an object}. Fix it. ${example} shows the shape."

if [ "${1:-}" = "--check" ]; then
  printf 'Config: %s\n' "${config}"
  exit 0
fi

dir="$(story_plans_dir)" || fail "cannot find the shared .plans folder. Run this inside a git checkout of the repo, or set STORY_PLANS_DIR."

# unbind <key>: removes the binding and the marks of one key.
unbind() {
  local k="$1"
  if [ ! -f "${dir}/.sessions/${k}.json" ]; then
    printf '%s was not bound.\n' "${k}"
    return 0
  fi
  rm -f "${dir}/.sessions/${k}.json" "${dir}/.sessions/${k}.crossed" "${dir}/.sessions/${k}.nudged" "${dir}/.sessions/${k}.blocked" \
    || fail "cannot remove the binding files of ${k} in ${dir}/.sessions."
  printf 'Unbound %s.\n' "${k}"
}

if [ "${1:-}" = "--unbind" ] && [ -n "${2:-}" ]; then
  [ "${2}" = "$(story_clean "${2}")" ] || fail "key '${2}' holds characters outside A-Z a-z 0-9 . _ -."
  unbind "${2}"
  exit 0
fi
key="$(story_key '{}')"
[ -n "${key}" ] || fail "no session id. Neither CLAUDE_CODE_HOST_SESSION_ID nor CLAUDE_CODE_SESSION_ID is set. Run this from the Bash tool of the session to bind."

if [ "${1:-}" = "--state" ]; then
  story_state_file '{}'
  exit 0
fi

if [ "${1:-}" = "--unbind" ]; then
  b="$(story_binding '{}')"
  [ -n "${b}" ] || { printf '%s was not bound.\n' "${key}"; exit 0; }
  unbind "$(basename "${b}" .json)"
  exit 0
fi

if [ "${1:-}" = "--show" ]; then
  b="$(story_binding '{}')"
  [ -n "${b}" ] || { printf 'unbound (key %s)\n' "${key}"; exit 0; }
  cat "${b}"
  exit 0
fi

role="${1:-}"
slug="${2:-}"
parent=""
[ "${3:-}" = "--parent" ] && parent="$(story_clean "${4:-}")"
case " ${story_roles} " in
  *" ${role} "*) ;;
  *) fail "role '${role}' is not one of: ${story_roles}. Usage: story-bind.sh <role> <slug> [--parent <id>]" ;;
esac
[ -n "${slug}" ] && [ "${slug}" = "$(story_clean "${slug}")" ] || fail "slug '${slug}' is empty or holds characters outside A-Z a-z 0-9 . _ -."

mkdir -p "${dir}/.sessions" "${dir}/${slug}.d" || fail "cannot create ${dir}/.sessions or ${dir}/${slug}.d."
file="${dir}/.sessions/${key}.json"
jq -n --arg role "${role}" --arg slug "${slug}" --arg parent "${parent}" \
  --arg sid "$(story_clean "${CLAUDE_CODE_SESSION_ID:-}")" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{role:$role, slug:$slug, state:"active", parent:$parent, bound_at:$at, session_id:$sid}' >"${file}" \
  || fail "cannot write ${file}."
printf 'Bound %s as %s of story %s.\n' "${key}" "${role}" "${slug}"
printf 'Binding: %s\n' "${file}"
printf 'Plan: %s/%s.md\n' "${dir}" "${slug}"
printf 'State: %s/%s.d/%s.md\n' "${dir}" "${slug}" "${role}"
