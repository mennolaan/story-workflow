#!/usr/bin/env bash
# Shared functions for the story hooks. Source it; it runs nothing.
# Procedure: skills/story/SKILL.md ("Files", "Context rule").
# All sessions of a story share one folder: the .plans/ folder of the main
# checkout, the parent of the git common dir. A binding file in
# .plans/.sessions/ names the role and the story of one session. Its key is
# CLAUDE_CODE_HOST_SESSION_ID (the desktop id, kept over /clear), else the
# Claude Code session id.
# A repo opts in with .claude/story.json in its main checkout
# (skills/story/story.example.json). Without that file story_enabled fails,
# and every automatic hook exits 0 with no output and no write.
# Overrides for tests: STORY_PLANS_DIR (the shared folder), STORY_CONFIG
# (the config file).
# Bash 3.2 compatible (the macOS /bin/bash).

# shellcheck disable=SC2034 # read by story-bind.sh, which sources this file.
story_roles="orchestrator plan implement pr-review"

# story_main_root: the main checkout root, the parent of the git common dir.
# Every worktree gives the same root. Exit 1 outside a git checkout.
story_main_root() {
  local common
  common="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "${common}" ] || return 1
  dirname "${common}"
}

story_plans_dir() {
  if [ -n "${STORY_PLANS_DIR:-}" ]; then
    printf '%s\n' "${STORY_PLANS_DIR}"
    return 0
  fi
  local root
  root="$(story_main_root)" || return 1
  printf '%s/.plans\n' "${root}"
}

# story_config_file: .claude/story.json of the main checkout root, the same
# file for every worktree session and for the context-keeper mod. Without
# git, the project dir.
story_config_file() {
  if [ -n "${STORY_CONFIG:-}" ]; then
    printf '%s\n' "${STORY_CONFIG}"
    return 0
  fi
  local root
  root="$(story_main_root)" || root="${CLAUDE_PROJECT_DIR:-.}"
  printf '%s/.claude/story.json\n' "${root}"
}

# story_enabled: the repo has opted in. Only a file test, so it works
# without jq.
story_enabled() { [ -f "$(story_config_file)" ]; }

# story_config <key> <default>
story_config() {
  local v
  v="$(jq -r --arg k "$1" '.[$k] // empty' "$(story_config_file)" 2>/dev/null)"
  printf '%s\n' "${v:-$2}"
}

story_clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'; }

# story_keys <hook input json>: the candidate binding keys, host id first.
story_keys() {
  local host sid
  host="$(story_clean "${CLAUDE_CODE_HOST_SESSION_ID:-}")"
  sid="$(story_clean "$(jq -r '.session_id // empty' <<<"$1" 2>/dev/null)")"
  [ -n "${sid}" ] || sid="$(story_clean "${CLAUDE_CODE_SESSION_ID:-}")"
  [ -n "${host}" ] && printf '%s\n' "${host}"
  [ -n "${sid}" ] && [ "${sid}" != "${host}" ] && printf '%s\n' "${sid}"
  return 0
}

# story_key <hook input json>: the key this session writes under.
story_key() { story_keys "$1" | head -n 1; }

# story_binding <hook input json>: the path of the binding file, or nothing.
story_binding() {
  local dir k
  dir="$(story_plans_dir)" || return 0
  while IFS= read -r k; do
    [ -n "${k}" ] || continue
    if [ -f "${dir}/.sessions/${k}.json" ]; then
      printf '%s\n' "${dir}/.sessions/${k}.json"
      return 0
    fi
  done <<<"$(story_keys "$1")"
  return 0
}

# story_field <binding file> <field>
story_field() { jq -r --arg f "$2" '.[$f] // empty' "$1" 2>/dev/null; }

story_is_child() {
  case "$1" in plan|implement|pr-review) return 0 ;; esac
  return 1
}

# story_state_file <hook input json>: the checkpoint path of this session.
# Bound: <plans>/<slug>.d/<role>.md. Unbound: <plans>/.sessions/<key>.md.
story_state_file() {
  local dir b role slug
  dir="$(story_plans_dir)" || return 1
  b="$(story_binding "$1")"
  if [ -n "${b}" ]; then
    role="$(story_field "${b}" role)"
    slug="$(story_field "${b}" slug)"
    printf '%s/%s.d/%s.md\n' "${dir}" "${slug}" "${role}"
  else
    printf '%s/.sessions/%s.md\n' "${dir}" "$(story_key "$1")"
  fi
}

# story_compact_dir <hook input json>
story_compact_dir() {
  local dir b
  dir="$(story_plans_dir)" || return 1
  b="$(story_binding "$1")"
  if [ -n "${b}" ]; then
    printf '%s/%s.d/compact\n' "${dir}" "$(story_field "${b}" slug)"
  else
    printf '%s/.sessions/compact\n' "${dir}"
  fi
}

# story_window <model id>: the context window in tokens. Native-1M models per
# code.claude.com/docs/en/model-config (as of 2026-10-27); unknown ids 200k.
story_window() {
  case "$1" in
    *"[1m]"*) echo 1000000 ;;
    *fable*) echo 1000000 ;;
    *sonnet-[5-9]*) echo 1000000 ;;
    *haiku-5-5*|*haiku-[6-9]*) echo 1000000 ;;
    *opus-4-[7-9]*|*opus-[5-9]*) echo 1000000 ;;
    *) echo 200000 ;;
  esac
}

# story_usage <transcript path>: "<tokens> <model>" of the last main-chain
# assistant line, or nothing. Usage from before the last compact_boundary is
# the old context, and the first response after a compaction is not in the
# file yet when PostToolUse runs, so a boundary with no usage after it gives
# nothing.
story_usage() {
  [ -f "$1" ] || return 0
  tail -n 400 "$1" 2>/dev/null \
    | awk '/"subtype":"compact_boundary"/ { n = 0; next } /"usage"/ { line[++n] = $0 } END { for (i = (n > 40 ? n - 39 : 1); i <= n; i++) print line[i] }' \
    | jq -R -r '
    fromjson?
    | select(.type == "assistant" and (.isSidechain | not) and .message.usage != null
             and (.message.model // "") != "<synthetic>")
    | "\((.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)
         + (.message.usage.cache_read_input_tokens // 0)) \(.message.model // "unknown")"' 2>/dev/null | tail -n 1
}

story_mtime() { date -r "$1" +%s 2>/dev/null || echo 0; }

# story_is_fresh <state file> <crossed epoch>: exists, 400+ characters, and
# written at or after the crossing.
story_is_fresh() {
  [ -f "$1" ] || return 1
  [ "$(wc -c <"$1" | tr -d ' ')" -ge 400 ] || return 1
  [ "$(story_mtime "$1")" -ge "${2:-0}" ]
}

# story_card <role> <slug> <parent>: the role card that re-primes a session.
story_card() {
  local role="$1" slug="$2" parent="${3:-unknown}"
  case "${role}" in
    orchestrator)
      printf 'You are the ORCHESTRATOR of story %s. You alone ask the user and act outward (board, push, PR, Azure, pipelines, paid runs). Read digests, not diffs. Keep the ledger current.\n' "${slug}" ;;
    plan)
      printf 'You are the PLAN session of story %s. You never ask the user. You own the plan file. Run /review-panel plan <plan> deep on the first full proposal, fold in the findings, then report PLAN READY. Your orchestrator is %s.\n' "${slug}" "${parent}" ;;
    implement)
      printf 'You are the IMPLEMENT session of story %s. You never ask the user and never push. You own the code, local commits and "## Implementation status" in the plan. Your orchestrator is %s.\n' "${slug}" "${parent}" ;;
    pr-review)
      printf 'You are the PR-REVIEW session of story %s. You never ask the user and never post. You own the pr-review file. Your orchestrator is %s.\n' "${slug}" "${parent}" ;;
  esac
}

story_protocol_line() {
  printf 'Protocol: end every turn with wrap_up. The first line of the recap is one token: PHASE DONE #<task> <sha>, PLAN READY <path>, QUESTION, DOCKET <path>, READY FOR LIVE CHECKS <branch> <sha>, READY TO PUSH <branch> <sha>, BLOCKED, CHECKPOINT or DONE. Set the title emoji for that token before wrap_up (map: %s/skills/story/SKILL.md). A question goes to the orchestrator with SendMessage, never to the user.\n' "${CLAUDE_PLUGIN_ROOT:-the story-workflow plugin}"
}
