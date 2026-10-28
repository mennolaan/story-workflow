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
#
# Backstop gate: binding a role refuses when the effective autoCompactWindow
# is missing or above backstopTokens of the config (default 432000). Without
# the key a 1M session compacts at about 967k tokens, far past the save point.
# The order follows code.claude.com/docs/en/settings ("Settings precedence"),
# /settings-reference ("autoCompactWindow"), /model-config ("Set the
# auto-compact window") and /managed-settings, all read 2026-10-28:
#   1. CLAUDE_CODE_AUTO_COMPACT_WINDOW: a token count, <n>k or <n>M, clamped
#      to 100000..1000000. Any other value is ignored, as Claude Code does.
#   2. Managed: the macOS plist com.anthropic.claudecode when it holds a policy
#      key, else managed-settings.json merged with managed-settings.d/*.json in
#      name order.
#   3. Local: <main root>/.claude/settings.local.json.
#   4. Project: <main root>/.claude/settings.json (a desktop worktree session
#      reads the main checkout, skills/story/SKILL.md).
#   5. User: ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json.
# Within one file, modelSettings.<model id>.autoCompactWindow wins over the
# top-level key for that model. The script does not know the model, so it
# checks every model a file names plus all others, and refuses when any of
# them is over. Not visible here: server-managed settings, the embedding host's
# managed settings, --settings and --autocompact. A file that is not a JSON
# object counts as empty, as Claude Code skips it.
# Overrides for tests: STORY_MANAGED_DIR, STORY_MANAGED_PLIST.
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

# settings_json <file>: the file as one JSON object, or {}.
settings_json() { jq -c 'if type == "object" then . else {} end' "$1" 2>/dev/null || printf '{}\n'; }

# managed_json: the managed tier as one JSON object (first source with a policy key wins).
managed_json() {
  local sysdir="${STORY_MANAGED_DIR:-}" plist="${STORY_MANAGED_PLIST:-/Library/Managed Preferences/com.anthropic.claudecode.plist}" p f
  if [ -z "${sysdir}" ]; then
    case "$(uname -s)" in Darwin) sysdir="/Library/Application Support/ClaudeCode" ;; *) sysdir=/etc/claude-code ;; esac
  fi
  if [ -f "${plist}" ] && command -v plutil >/dev/null 2>&1; then
    p="$(plutil -convert json -o - "${plist}" 2>/dev/null)"
    if jq -e 'type == "object" and (del(.managedSourcesBehavior, .wslInheritsWindowsSettings) | length > 0)' >/dev/null 2>&1 <<<"${p}"; then
      jq -c . <<<"${p}"
      return 0
    fi
  fi
  {
    settings_json "${sysdir}/managed-settings.json"
    for f in "${sysdir}"/managed-settings.d/*.json; do
      [ -f "${f}" ] && settings_json "${f}"
    done
  } | jq -cs 'reduce .[] as $x ({}; . * $x)'
}

# env_window: CLAUDE_CODE_AUTO_COMPACT_WINDOW as tokens, or exit 1 when Claude Code would ignore it.
env_window() {
  local v="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" n
  if [[ "${v}" =~ ^([0-9]+)$ ]]; then n=$((10#${BASH_REMATCH[1]}))
  elif [[ "${v}" =~ ^([0-9]+)[kK]$ ]]; then n=$((10#${BASH_REMATCH[1]} * 1000))
  elif [[ "${v}" =~ ^([0-9]+)M$ ]]; then n=$((10#${BASH_REMATCH[1]} * 1000000))
  else return 1
  fi
  [ "${n}" -lt 100000 ] && n=100000
  [ "${n}" -gt 1000000 ] && n=1000000
  printf '%s\n' "${n}"
}

# backstop_gate: exit 1 with the fix when the effective autoCompactWindow is missing or above backstopTokens.
backstop_gate() {
  local max root user_f local_f proj_f lines model value from bad="" n
  max="$(story_config backstopTokens 432000)"
  [[ "${max}" =~ ^[0-9]+$ ]] || fail "backstopTokens in ${config} is '${max}', not a token count. Set it to a number such as 432000."
  if n="$(env_window)"; then
    [ "${n}" -le "${max}" ] && return 0
    fail "the effective autoCompactWindow is ${n} from CLAUDE_CODE_AUTO_COMPACT_WINDOW, above backstopTokens ${max} in ${config}. A session would compact long after the save point. Unset the variable or set it to at most ${max}, then start the session again."
  fi
  root="$(story_main_root)" || root="${CLAUDE_PROJECT_DIR:-.}"
  user_f="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"
  local_f="${root}/.claude/settings.local.json"
  proj_f="${root}/.claude/settings.json"
  lines="$({ managed_json; settings_json "${local_f}"; settings_json "${proj_f}"; settings_json "${user_f}"; } | jq -rs --args '
    . as $sc | $ARGS.positional as $names
    | def w($s; $m):
        if $m == "*" then $s.autoCompactWindow
        else ((($s.modelSettings // {}) | if type == "object" then .[$m] else null end | if type == "object" then .autoCompactWindow else null end) // $s.autoCompactWindow)
        end;
      ([$sc[] | (.modelSettings // {}) | objects | to_entries[] | select(.value | type == "object" and .autoCompactWindow != null) | .key] | unique) + ["*"]
    | .[] as $m
    | (first(range(0; $sc | length) as $i | w($sc[$i]; $m) | select(. != null) | [$m, (. | tostring), $names[$i]]) // [$m, "", ""])
    | @tsv' "managed settings" "${local_f}" "${proj_f}" "${user_f}")" \
    || fail "cannot read the settings files with jq, so the backstop check did not run."
  while IFS=$'\t' read -r model value from; do
    [ -n "${model}" ] || continue
    [ "${model}" = "*" ] && model="every model" || model="model ${model}"
    if [ -z "${value}" ]; then
      bad="${bad} No autoCompactWindow is set for ${model}."
    elif ! [[ "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -gt "${max}" ]; then
      bad="${bad} The effective autoCompactWindow for ${model} is ${value} from ${from}."
    fi
  done <<<"${lines}"
  [ -z "${bad}" ] && return 0
  fail "the backstop is off.${bad} backstopTokens in ${config} is ${max}, so a session would compact long after the save point. Set \"autoCompactWindow\": ${max} (or lower) in ${proj_f}, and remove higher values from ${local_f}. Precedence, highest first: CLAUDE_CODE_AUTO_COMPACT_WINDOW, managed settings, ${local_f}, ${proj_f}, ${user_f}."
}

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

backstop_gate

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
