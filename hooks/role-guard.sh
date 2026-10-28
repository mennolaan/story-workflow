#!/usr/bin/env bash
# Claude Code PreToolUse (AskUserQuestion|Bash): a bound child session (plan,
# implement, pr-review) does not ask the user and does not act outward. Only
# the orchestrator does (skills/story/SKILL.md, "Authority").
# Denied for a child role:
#   AskUserQuestion
#   git push
#   az repos pr, every command except show, list, checkout and <group> list
#   az boards work-item, every command except show and relation show|list-type
#   az pipelines run, az pipelines build queue
#   gh pr, every command except view, list, diff, checks, status and checkout
#   gh issue, every command except view, list and status
#   (gh flags such as -R <repo> may stand before or after pr and issue)
#   gh api with a method other than GET, or with -f, -F, --field,
#   --raw-field or --input and no explicit GET (gh then sends a POST)
#   each Perl regex in "guard.deny" of .claude/story.json
# in Bash and in mcp__terminal__run_in_terminal (the user's own shell).
# role-guard.pl parses the command into shell words, so a quoted verb
# (gh pr "merge") is a verb and an argument (a commit message, echo text, a
# grep pattern) is never a command. Its header lists what it parses and how
# guard.deny matches. A command it cannot parse denies the child.
# Without .claude/story.json every call passes with no output (story_enabled).
# The orchestrator and unbound sessions pass with no parsing.
# mcp__ccd_session_mgmt__clear_session gets "allow" only for a bound
# orchestrator whose target is bound with the orchestrator as its parent, so
# the orchestrator resets its own idle child with no prompt. Every other call
# gets "ask" (a prompt even in auto mode). No settings allow rule is needed,
# and a repo should keep none: it would grant every reset with no check.
# Deny is the JSON permissionDecision form (code.claude.com/docs/en/hooks,
# as of 2026-10-27). The guard fails closed for a bound child: without jq,
# with a config it cannot read, or with a bad guard.deny entry, every call
# of the child is denied with the reason. For other sessions, without jq or
# on an input that is not JSON, it exits 1 with the reason: a non-blocking
# error the user sees. Without jq a clear_session call gets a fixed "ask", so
# a leftover settings allow rule cannot approve it with no check.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

# nojq_child: the session is bound to a child role. Bash built-ins and grep
# only, because it runs when jq is missing.
nojq_child() {
  local dir k sid=""
  dir="$(story_plans_dir)" || return 1
  [[ "${input}" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]*)\" ]] && sid="${BASH_REMATCH[1]}"
  for k in "${CLAUDE_CODE_HOST_SESSION_ID//[^A-Za-z0-9._-]/}" "${sid}" "${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9._-]/}"; do
    [ -n "${k}" ] && [ -f "${dir}/.sessions/${k}.json" ] || continue
    grep -Eq '"role"[[:space:]]*:[[:space:]]*"(plan|implement|pr-review)"' "${dir}/.sessions/${k}.json"
    return
  done
  return 1
}

input="$(cat)"
story_enabled || exit 0
if ! command -v jq >/dev/null 2>&1; then
  if grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"mcp__ccd_session_mgmt__clear_session"' <<<"${input}"; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"role-guard: jq is not on PATH, so the clear_session check did not run. Approve only the clear of your own idle child. Install jq (brew install jq)."}}'
    exit 0
  fi
  if nojq_child; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"role-guard: jq is not on PATH, so the guard cannot check a command of this bound child session, and denies it. Install jq (brew install jq)."}}'
    exit 0
  fi
  echo "role-guard: jq is not on PATH, so the guard did not run. Install it (brew install jq)." >&2
  exit 1
fi
jq -e . >/dev/null 2>&1 <<<"${input}" || { echo "role-guard: the hook input is not JSON, so the guard did not run. Input: ${input:0:200}" >&2; exit 1; }

b="$(story_binding "${input}")"
tool="$(jq -r '.tool_name // empty' <<<"${input}")"

if [ "${tool}" = mcp__ccd_session_mgmt__clear_session ]; then
  target="$(jq -r '.tool_input.session_id // empty' <<<"${input}")"
  ask() {
    jq -cn --arg r "role-guard: clear_session of ${target:-an unnamed session} needs your approval, because $1. Only an orchestrator that resets its own bound child gets no prompt." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    exit 0
  }
  [ -n "${b}" ] || ask "this session is not bound to a story"
  [ "$(story_field "${b}" role)" = orchestrator ] || ask "this session is not an orchestrator"
  [ -n "${target}" ] && [ "${target}" != self ] || ask "the target is this session itself"
  [ "${target}" = "$(story_clean "${target}")" ] || ask "the target id holds characters outside A-Z a-z 0-9 . _ -"
  dir="$(story_plans_dir)" || ask "the shared .plans folder is not found"
  tb="${dir}/.sessions/${target}.json"
  [ -f "${tb}" ] || ask "the target is not bound to a story"
  [ "$(story_field "${tb}" parent)" = "$(basename "${b}" .json)" ] || ask "the target is not a child of this orchestrator"
  jq -cn --arg r "role-guard: the orchestrator resets its own bound child ${target}." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}'
  exit 0
fi

[ -n "${b}" ] || exit 0
role="$(story_field "${b}" role)"
story_is_child "${role}" || exit 0
slug="$(story_field "${b}" slug)"
parent="$(story_field "${b}" parent)"

deny() {
  jq -cn --arg r "role-guard: the ${role} session of story ${slug} does not $1. Only the orchestrator (${parent:-see the binding}) does that. Send a QUESTION with the options and your recommendation to the orchestrator with SendMessage, then end the turn." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

case "${tool}" in
  AskUserQuestion) deny "ask the user (AskUserQuestion)" ;;
  Bash|mcp__terminal__run_in_terminal) ;;
  *) exit 0 ;;
esac

cmd="$(jq -r '.tool_input.command // empty' <<<"${input}")"
[ -n "${cmd}" ] || exit 0
config="$(story_config_file)"
broken=""
extra="$(jq -r '(.guard.deny // []) | if type == "array" and all(.[]; type == "string") then .[] else error("guard.deny is not a list of strings") end' "${config}" 2>&1)" \
  || { broken="${extra}"; extra=""; }

sessions="$(story_plans_dir 2>/dev/null)/.sessions"
hit="$(printf '%s' "${cmd}" | STORY_GUARD_DENY="${extra}" STORY_SESSIONS_DIR="${sessions}" perl "${here}/role-guard.pl")" \
  || deny "run a command while the command check (role-guard.pl) failed. Ask the orchestrator to check perl"
IFS=$'\t' read -r kind what why <<<"${hit}"
case "${kind}" in
  deny) deny "${what}" ;;
  parse) deny "run a command that the guard cannot parse: ${what}. Rewrite it with balanced quotes" ;;
  bad) deny "run any command while the guard.deny entry '${what}' in ${config} is not a valid Perl regex (${why}). Ask the orchestrator to fix the entry" ;;
esac
[ -n "${broken}" ] && deny "run any command while ${config} cannot be read as a list of guard.deny regex strings (${broken}). Ask the orchestrator to fix the file"
exit 0
