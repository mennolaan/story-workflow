#!/usr/bin/env bash
# Held-out check for the story hooks: context-guard.sh, session-reprime.sh,
# role-guard.sh, pre-compact.sh, post-compact.sh, story-bind.sh, the bound
# branch of plan-boundary.sh, the hook routing in hooks/hooks.json, and the
# skill files of the story-workflow plugin.
# Every case is falsifying: it fails when the branch it names is removed.
# Fixtures live in a temp folder (STORY_PLANS_DIR, STORY_CONFIG). The session
# ids of the calling session are unset, so a run inside Claude Code tests the
# fixtures only. Runs shellcheck on every hook when it is installed.
# Usage: tests/story-hooks-matrix.sh   (from the plugin root; exit 0 = all cases pass)
# shellcheck disable=SC2015,SC2016 # pass and fail return 0; backticks in single quotes are literal Markdown.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hooks="${repo}/hooks"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
plans="${tmp}/plans"
mkdir -p "${plans}/.sessions"
printf '{"checkpointPercent": 35, "backstopTokens": 432000, "planBoundary": true}\n' >"${tmp}/config.json"

rc=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n%s\n' "$1" "${2:-}" >&2; rc=1; }

# hook <script> <json> [KEY=VALUE ...]: sets out (stdout) and code (exit code).
code=0
hook() {
  local script="$1" json="$2"
  shift 2
  out="$(printf '%s' "${json}" | env -u CLAUDE_CODE_HOST_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    STORY_PLANS_DIR="${plans}" STORY_CONFIG="${tmp}/config.json" CLAUDE_PROJECT_DIR="${repo}" "$@" \
    "${hooks}/${script}" 2>"${tmp}/stderr")"
  code=$?
}

# transcript <name> <tokens> <model> [sidechain tokens]: a transcript fixture.
transcript() {
  local f="${tmp}/$1.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' >"${f}"
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$3" "$2" >>"${f}"
  [ -n "${4:-}" ] && printf '{"type":"assistant","isSidechain":true,"message":{"model":"%s","usage":{"input_tokens":%s}}}\n' "$3" "$4" >>"${f}"
  printf '%s' "${f}"
}

ptu() { printf '{"hook_event_name":"PostToolUse","session_id":"%s","transcript_path":"%s","tool_name":"Read"}' "$1" "$2"; }
stop() { printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$1" "$2" "${3:-false}"; }
bind() { # bind <key> <role> <slug>
  printf '{"role":"%s","slug":"%s","state":"active","parent":"local_orch","bound_at":"2026-10-27T00:00:00Z","session_id":"%s"}\n' "$2" "$3" "$1" >"${plans}/.sessions/$1.json"
  mkdir -p "${plans}/$3.d"
}
long_state() { # long_state <file>: a checkpoint of 400+ characters
  mkdir -p "$(dirname "$1")"
  { printf '# Checkpoint\n'; for _ in 1 2 3 4 5 6 7 8 9 10; do printf 'Done and verified: step with evidence, line of filler text.\n'; done
    printf 'CHECKPOINT-READY: %s | continue\n' "$1"; } >"$1"
}

# 0. a repo without .claude/story.json: every automatic hook is silent and
# writes no .plans/. Real git checkouts, no STORY_PLANS_DIR, no STORY_CONFIG.
bare_hook() { # bare_hook <project dir> <script> <json>: sets out and code
  out="$(printf '%s' "$3" | env -u CLAUDE_CODE_HOST_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u STORY_PLANS_DIR -u STORY_CONFIG \
    CLAUDE_PROJECT_DIR="$1" TMPDIR="$1.tmp" "${hooks}/$2" 2>"${tmp}/stderr")"
  code=$?
}
bare_all() { # bare_all <project dir>: runs every automatic hook, prints what each printed
  local t
  t="$(transcript "bare-$(basename "$1")" 360000 claude-opus-5-5)"
  mkdir -p "$1.tmp"
  bare_hook "$1" context-guard.sh "$(ptu nc-impl "${t}")"; printf '%s' "${out}"
  bare_hook "$1" context-guard.sh "$(stop nc-impl "${t}")"; printf '%s' "${out}"
  bare_hook "$1" session-reprime.sh '{"hook_event_name":"SessionStart","source":"startup","session_id":"nc-impl"}'; printf '%s' "${out}"
  bare_hook "$1" pre-compact.sh "$(jq -cn --arg t "${t}" '{hook_event_name:"PreCompact",session_id:"nc-impl",trigger:"auto",transcript_path:$t}')"; printf '%s' "${out}"
  bare_hook "$1" post-compact.sh '{"hook_event_name":"PostCompact","session_id":"nc-impl","trigger":"auto","compact_summary":"S"}'; printf '%s' "${out}"
  bare_hook "$1" role-guard.sh "$(jq -cn '{hook_event_name:"PreToolUse",session_id:"nc-impl",tool_name:"Bash",tool_input:{command:"git push"}}')"; printf '%s' "${out}"
  bare_hook "$1" role-guard.sh "$(jq -cn '{hook_event_name:"PreToolUse",session_id:"nc-impl",tool_name:"mcp__ccd_session_mgmt__clear_session",tool_input:{session_id:"x"}}')"; printf '%s' "${out}"
  bare_hook "$1" lint-mark.sh '{"hook_event_name":"PreToolUse","session_id":"nc-impl","tool_name":"Bash","tool_input":{"command":"true"}}'; printf '%s' "${out}"
  bare_hook "$1" plan-boundary.sh '{"hook_event_name":"PostToolUse","session_id":"nc-impl","tool_name":"Bash","tool_input":{"command":"true"}}'; printf '%s' "${out}"
}
listing() { find "$@" 2>/dev/null | sort; }
nc="${tmp}/nocfg"
mkdir -p "${nc}" && git -C "${nc}" init -q
o="$(bare_all "${nc}")"
[ -z "${o}" ] && [ ! -e "${nc}/.plans" ] && [ -z "$(listing "${nc}.tmp" -type f)" ] \
  && pass "no config: no hook prints, and none writes .plans/ or a stamp" \
  || fail "no config: a hook printed or wrote" "out: ${o}; files: $(listing "${nc}/.plans" "${nc}.tmp" -type f)"
# A bound session in a repo that later lost its story.json.
nb="${tmp}/nocfg-bound"
mkdir -p "${nb}/.plans/.sessions/" "${nb}/.plans/story-n.d" && git -C "${nb}" init -q
printf '{"role":"implement","slug":"story-n","state":"active","parent":"local_orch"}\n' >"${nb}/.plans/.sessions/nc-impl.json"
printf '# Plan\n\n## Review\n' >"${nb}/.plans/story-n.md"
before="$(listing "${nb}/.plans")"
o="$(bare_all "${nb}")"
[ -z "${o}" ] && [ "$(listing "${nb}/.plans")" = "${before}" ] \
  && pass "no config: a bound child gets no re-prime, no guard and no file in .plans/" \
  || fail "no config: a bound child got output or a new file" "out: ${o}; new: $(diff <(printf '%s\n' "${before}") <(listing "${nb}/.plans"))"
mkdir -p "${nb}/.claude" && cp "${tmp}/config.json" "${nb}/.claude/story.json"
o="$(bare_all "${nb}")"
[[ "${o}" == *'IMPLEMENT session of story story-n'* && "${o}" == *'"permissionDecision":"deny"'* ]] && [ -e "${nb}/.plans/.sessions/nc-impl.crossed" ] \
  && pass "config: the same inputs with .claude/story.json re-prime, guard and mark the crossing" \
  || fail "config: .claude/story.json of the main checkout is not read" "out: ${o}"

# 1. context-guard on PostToolUse
t="$(transcript below 100000 claude-opus-5-5)"
hook context-guard.sh "$(ptu s-below "${t}")"; [ -z "${out}" ] && pass "guard: below 35% is silent" || fail "guard: below 35% printed output" "${out}"
t="${tmp}/cache.jsonl"
printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":10000,"cache_creation_input_tokens":0,"cache_read_input_tokens":350000}}}\n' >"${t}"
hook context-guard.sh "$(ptu s-cache "${t}")"
[[ "${out}" == *"360000 of 1000000"* ]] && pass "guard: cache-read tokens count toward the context (360000)" || fail "guard: cache-read tokens not counted" "${out}"

t="$(transcript cross 360000 claude-opus-5-5)"
hook context-guard.sh "$(ptu s-cross "${t}")"; o="${out}"
[[ "${o}" == *'"additionalContext"'*'/checkpoint'* ]] && pass "guard: the crossing nudges once" || fail "guard: no nudge at the crossing" "${o}"
hook context-guard.sh "$(ptu s-cross "${t}")"; [ -z "${out}" ] && pass "guard: no second nudge for the same crossing" || fail "guard: second nudge" "${out}"

t="$(transcript sonnet 300000 claude-sonnet-5-5)"
hook context-guard.sh "$(ptu s-sonnet "${t}")"; [ -z "${out}" ] && pass "guard: claude-sonnet-5-5 has a 1M window (300k is 30%)" || fail "guard: sonnet-5-5 treated as 200k" "${out}"
[ "$(bash -c '. "$1/story-lib.sh"; story_window some-new-model' _ "${hooks}")" = 200000 ] \
  && pass "guard: an unknown model has a 200k window" || fail "guard: unknown model not treated as 200k"
for m in claude-opus-4-6 some-new-model; do
  t="$(transcript "w200-${m}" 150000 "${m}")"
  hook context-guard.sh "$(ptu "s-w200-${m}" "${t}")"; o="${out}"
  hook context-guard.sh "$(stop "s-w200-${m}" "${t}")"
  [ -z "${o}" ] && [ -z "${out}" ] && [ ! -e "${plans}/.sessions/s-w200-${m}.crossed" ] \
    && pass "guard: ${m} (200k window) at 75% is silent, no nudge and no Stop gate" || fail "guard: ${m} under the 400k window floor nudged or blocked" "ptu: ${o} stop: ${out}"
done

t="$(transcript side 100000 claude-opus-5-5 900000)"
hook context-guard.sh "$(ptu s-side "${t}")"; [ -z "${out}" ] && pass "guard: a sidechain line does not count" || fail "guard: sidechain tokens counted" "${out}"

t="$(transcript recross-low 100000 claude-opus-5-5)"
hook context-guard.sh "$(ptu s-cross "${t}")" >/dev/null
[ ! -e "${plans}/.sessions/s-cross.crossed" ] && pass "guard: below the threshold clears the crossing" || fail "guard: crossing kept below the threshold"
t="$(transcript cross 360000 claude-opus-5-5)"
hook context-guard.sh "$(ptu s-cross "${t}")"; [[ "${out}" == *additionalContext* ]] && pass "guard: a new crossing nudges again" || fail "guard: no nudge on the second crossing" "${out}"

printf '{"checkpointPercent": 50, "backstopTokens": 600000}\n' >"${tmp}/config.json"
t="$(transcript cfg 400000 claude-opus-5-5)"
hook context-guard.sh "$(ptu s-cfg "${t}")"; [ -z "${out}" ] && pass "guard: checkpointPercent comes from config.json" || fail "guard: config.json ignored" "${out}"
printf '{"checkpointPercent": 35, "backstopTokens": 432000, "planBoundary": true}\n' >"${tmp}/config.json"

# 2. context-guard on Stop
t="$(transcript stop 360000 claude-opus-5-5)"
hook context-guard.sh "$(stop s-stop "${t}")"; o="${out}"
[[ "${o}" == *'"decision":"block"'* ]] && pass "stop: a stale checkpoint blocks" || fail "stop: no block on a stale checkpoint" "${o}"
hook context-guard.sh "$(stop s-stop "${t}")"; [ -z "${out}" ] && pass "stop: one block per crossing" || fail "stop: blocked twice" "${out}"
hook context-guard.sh "$(stop s-active "${t}" true)"; [ -z "${out}" ] && pass "stop: stop_hook_active passes" || fail "stop: blocked with stop_hook_active" "${out}"
bind s-fresh implement story-a
hook context-guard.sh "$(ptu s-fresh "${t}")" >/dev/null
long_state "${plans}/story-a.d/implement.md"
hook context-guard.sh "$(stop s-fresh "${t}")"; [ -z "${out}" ] && pass "stop: a fresh checkpoint passes" || fail "stop: blocked with a fresh checkpoint" "${out}"
printf 'short\n' >"${plans}/story-a.d/implement.md"
rm -f "${plans}/.sessions/s-fresh.blocked"
hook context-guard.sh "$(stop s-fresh "${t}")"; [[ "${out}" == *block* ]] && pass "stop: a checkpoint under 400 characters is stale" || fail "stop: short checkpoint counted as fresh" "${out}"
rm -f "${plans}/.sessions/s-fresh.blocked"
long_state "${plans}/story-a.d/implement.md"
printf '%s\n' "$(( $(date +%s) + 100 ))" >"${plans}/.sessions/s-fresh.crossed"
hook context-guard.sh "$(stop s-fresh "${t}")"; [[ "${out}" == *block* ]] && pass "stop: a checkpoint older than the crossing is stale" || fail "stop: old checkpoint counted as fresh" "${out}"

# 2b. usage from before the last compact_boundary is the old context. With a
# 5% save point, the old 169310 tokens (16%) would nudge and block.
printf '{"checkpointPercent": 5}\n' >"${tmp}/config5.json"
t="$(transcript compacted 169310 claude-opus-5-5)"
printf '{"type":"system","subtype":"compact_boundary","isSidechain":false,"content":"Conversation compacted"}\n' >>"${t}"
hook context-guard.sh "$(ptu s-cb "${t}")" STORY_CONFIG="${tmp}/config5.json"
[ -z "${out}" ] && pass "guard: no usage after a compact_boundary is silent" || fail "guard: old usage before the boundary nudged" "${out}"
hook context-guard.sh "$(stop s-cb "${t}")" STORY_CONFIG="${tmp}/config5.json"
[ -z "${out}" ] && pass "stop: no usage after a compact_boundary, no block" || fail "stop: old usage before the boundary blocked" "${out}"
printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":95957,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' >>"${t}"
hook context-guard.sh "$(ptu s-cb "${t}")" STORY_CONFIG="${tmp}/config5.json"
[[ "${out}" == *"Context 9% (95957 of 1000000"* ]] && pass "guard: usage after the boundary counts (9%)" || fail "guard: usage after the boundary not read" "${out}"

# 3. session-reprime
bind s-impl implement story-b
long_state "${plans}/story-b.d/implement.md"
printf '# other\n' >"${plans}/zz-newer-story.md"
touch -t 203001010000 "${plans}/zz-newer-story.md"
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"compact","session_id":"s-impl"}'; o="${out}"
[[ "${o}" == *"IMPLEMENT session of story story-b"* && "${o}" == *"Done and verified"* && "${o}" == *"Protocol:"* && "${o}" != *zz-newer-story* ]] \
  && pass "reprime: bound prints the role, its state and the protocol, not the newest plan" || fail "reprime: bound output wrong" "${o}"
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"startup","session_id":"s-nobody"}'; [ -z "${out}" ] && pass "reprime: unbound prints nothing" || fail "reprime: unbound printed output" "${out}"
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"resume","session_id":"s-impl"}'; [ -z "${out}" ] && pass "reprime: resume prints nothing" || fail "reprime: printed on resume" "${out}"
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"clear","session_id":"s-impl"}' CLAUDE_CODE_HOST_SESSION_ID=local_host1; o="${out}"
[[ "${o}" == *"story-b"* ]] && pass "reprime: a binding under session_id resolves once a host id is set" || fail "reprime: binding lost when the key changed" "${o}"
bind local_host2 plan story-c
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"clear","session_id":"new-after-clear"}' CLAUDE_CODE_HOST_SESSION_ID=local_host2; o="${out}"
[[ "${o}" == *"PLAN session of story story-c"* && "${o}" == *"No saved state yet"* ]] && pass "reprime: the host id binding survives a new session_id" || fail "reprime: host id binding not used" "${o}"
bind s-orch orchestrator story-c
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"startup","session_id":"s-orch"}'; o="${out}"
[[ "${o}" == *ORCHESTRATOR* && "${o}" == *ledger.md* && "${o}" != *"Protocol:"* ]] && pass "reprime: the orchestrator gets its card and the ledger, no child protocol" || fail "reprime: orchestrator output wrong" "${o}"

# 4. role-guard, table-driven
cmds=(
  "AskUserQuestion|"
  "Bash|git push"
  "Bash|git push -u origin feature/577-x"
  "Bash|git -C \"/Users/x/Team EIFFEL - LEAN\" push origin HEAD"
  "Bash|cd backend && git push --force-with-lease"
  "Bash|az repos pr create --draft --source-branch a --target-branch development"
  "Bash|az repos pr update --id 5 --status completed"
  "Bash|az repos pr set-vote --id 5 --vote approve"
  "Bash|az boards work-item create --type Task --title x"
  "Bash|az boards work-item update --id 5 --state Done"
  "Bash|az boards work-item delete --id 5 --yes"
  "Bash|az boards work-item relation add --id 5 --relation-type parent --target-id 6"
  "Bash|az repos pr reviewer add --id 5 --reviewers x"
  "Bash|az repos pr work-item add --id 5 --work-items 6"
  "Bash|az repos pr policy queue --id 5 --evaluation-id x"
  "Bash|az pipelines run --name eiffel-quality"
  "Bash|az pipelines build queue --definition-name x"
  "Bash|bash -c 'git push origin HEAD'"
  "Bash|sh -c \"git push\""
  "Bash|zsh -lc 'cd backend && git push'"
  "Bash|eval 'git push origin x'"
  "Bash|bash -cl 'git push'"
  "Bash|bash --norc -c 'git push'"
  "Bash|bash -c -l 'git push'"
  "mcp__terminal__run_in_terminal|git push origin HEAD"
  "Bash|/usr/bin/git push origin HEAD"
  $'Bash|bash <<\'EOF\'\ngit push origin HEAD\nEOF'
  $'Bash|cat <<EOF | sh\ngit push\nEOF'
  "Bash|bash <<< \"git push origin HEAD\""
  "Bash|echo 'git push origin HEAD' | bash"
  "Bash|printf 'git push\\n' | sh"
  "Bash|bash -s \"\$(git push origin HEAD)\" <<< 'true'"
  "Bash|bash -s \"\$(git push origin HEAD)\" <<< \"true\""
  "Bash|bash -s \$(git push origin HEAD) <<< 'true'"
)
guard_in() { # guard_in <key> <tool> <command>
  jq -cn --arg s "$1" --arg t "$2" --arg c "$3" \
    'if $t == "Bash" or $t == "mcp__terminal__run_in_terminal" then {hook_event_name:"PreToolUse",session_id:$s,tool_name:$t,tool_input:{command:$c}}
     elif $t == "mcp__ccd_session_mgmt__clear_session" then {hook_event_name:"PreToolUse",session_id:$s,tool_name:$t,tool_input:{session_id:$c}}
     else {hook_event_name:"PreToolUse",session_id:$s,tool_name:$t,tool_input:{questions:[]}} end'
}
bind g-plan plan story-g
bind g-implement implement story-g
bind g-pr-review pr-review story-g
bind g-orchestrator orchestrator story-g
for role in plan implement pr-review orchestrator unbound; do
  for row in "${cmds[@]}"; do
    tool="${row%%|*}"
    c="${row#*|}"
    hook role-guard.sh "$(guard_in "g-${role}" "${tool}" "${c}")"; o="${out}"
    if [ "${role}" = orchestrator ] || [ "${role}" = unbound ]; then
      [ -z "${o}" ] && [ "${code}" -eq 0 ] && pass "role-guard: ${role} may ${tool} ${c}" || fail "role-guard: ${role} denied ${tool} ${c}" "${o}"
    else
      [[ "${o}" == *'"permissionDecision":"deny"'* ]] && pass "role-guard: ${role} denied ${tool} ${c}" || fail "role-guard: ${role} not denied ${tool} ${c}" "${o}"
    fi
  done
done
heredoc="$(printf "cat <<'EOF' > notes.md\ngit push --dry-run\naz pipelines run --name x\nEOF\ngit status")"
hook role-guard.sh "$(guard_in g-implement Bash "${heredoc}")"; [ -z "${out}" ] && pass "role-guard: git push inside a heredoc is not a push" || fail "role-guard: heredoc body denied" "${out}"
quoted="git commit -m \"docs: say why git push stays with the orchestrator\""
hook role-guard.sh "$(guard_in g-implement Bash "${quoted}")"; [ -z "${out}" ] && pass "role-guard: git push inside a quoted message is not a push" || fail "role-guard: quoted text denied" "${out}"
subst="echo \"\$(git push origin x)\""
hook role-guard.sh "$(guard_in g-implement Bash "${subst}")"; [[ "${out}" == *deny* ]] && pass "role-guard: git push in a command substitution is denied" || fail "role-guard: command substitution passed" "${out}"
for c in "git status" "git commit -m x" "az repos pr show --id 5" "az repos pr list" "az repos pr reviewer list --id 5" "az boards work-item show --id 577" "az boards work-item relation show --id 5" "git log --oneline"; do
  hook role-guard.sh "$(guard_in g-implement Bash "${c}")"; [ -z "${out}" ] && pass "role-guard: implement may run ${c}" || fail "role-guard: false positive on ${c}" "${out}"
done
hook role-guard.sh "$(guard_in g-implement Bash "python3 -c 'print(1)' && git status")"; [ -z "${out}" ] && pass "role-guard: a quoted -c script without a push passes" || fail "role-guard: false positive on python3 -c" "${out}"
for c in "git commit -m 'git push later'" "echo 'bash -c git push'" $'git commit -F - <<\'EOF\'\ndocs: git push stays with the orchestrator\nEOF' "echo 'git push' | grep -c push" "echo 'git push' | shellcheck -"; do
  hook role-guard.sh "$(guard_in g-implement Bash "${c}")"; [ -z "${out}" ] && pass "role-guard: implement may run ${c}" || fail "role-guard: false positive on ${c}" "${out}"
done
# 4f. clear_session: no decision only for an orchestrator that clears its own bound child
printf '{"role":"implement","slug":"story-g","state":"active","parent":"g-orchestrator"}\n' >"${plans}/.sessions/g-child.json"
cs=mcp__ccd_session_mgmt__clear_session
hook role-guard.sh "$(guard_in g-orchestrator "${cs}" g-child)"; [ -z "${out}" ] && [ "${code}" -eq 0 ] && pass "clear-gate: the orchestrator clears its own child with no prompt" || fail "clear-gate: own child not passed" "${out}"
for row in "g-implement|g-child|a child caller" "g-orchestrator|g-plan|a target with another parent" "g-orchestrator|g-none|an unbound target" "g-orchestrator|self|self" "g-unbound|g-child|an unbound caller"; do
  IFS='|' read -r caller target why <<<"${row}"
  hook role-guard.sh "$(guard_in "${caller}" "${cs}" "${target}")"
  [[ "${out}" == *'"permissionDecision":"ask"'* ]] && pass "clear-gate: ${why} gets ask" || fail "clear-gate: ${why} not asked" "${out}"
done
jq -e '.hooks.PreToolUse[] | select(.matcher | split("|") | (index("Bash") and index("mcp__terminal__run_in_terminal") and index("mcp__ccd_session_mgmt__clear_session"))) | .hooks[].command == "\"${CLAUDE_PLUGIN_ROOT}/hooks/role-guard.sh\""' \
  "${hooks}/hooks.json" >/dev/null && pass "role-guard: hooks.json routes run_in_terminal and clear_session to the guard" || fail "role-guard: no PreToolUse entry in hooks/hooks.json with Bash, mcp__terminal__run_in_terminal and mcp__ccd_session_mgmt__clear_session in its matcher has exactly the command that runs hooks/role-guard.sh from the plugin root"
hook role-guard.sh 'not json' >/dev/null
[ "${code}" -eq 1 ] && grep -q "not JSON" "${tmp}/stderr" && pass "role-guard: a non-JSON input fails loud (exit 1)" || fail "role-guard: non-JSON input exit ${code}"

# 4b. config: autoCompactWindow equals backstopTokens
check_config() { # check_config <settings> <config>
  local a b
  a="$(jq -r '.autoCompactWindow // empty' "$1" 2>/dev/null)"
  b="$(jq -r '.backstopTokens // empty' "$2" 2>/dev/null)"
  [ -n "${a}" ] && [ "${a}" = "${b}" ]
}
printf '{"autoCompactWindow": 432000}\n' >"${tmp}/settings.json"
check_config "${tmp}/settings.json" "${tmp}/config.json" \
  && pass "config: the check passes autoCompactWindow equal to backstopTokens" \
  || fail "config: the check failed on equal values" "$(cat "${tmp}/settings.json" "${tmp}/config.json")"
printf '{"backstopTokens": 450000}\n' >"${tmp}/config-mismatch.json"
check_config "${tmp}/settings.json" "${tmp}/config-mismatch.json" && fail "config: the check passed a mismatch" || pass "config: the check fails on a mismatch"

# 4b2. repo files come from the main checkout root, also in a worktree.
# Fixture: a main checkout with checkpointPercent 35 and a worktree with 90.
# The guard runs with the worktree as project dir and no STORY_CONFIG.
main="${tmp}/main"
mkdir -p "${main}/.claude"
printf '{"checkpointPercent": 35, "planBoundary": true}\n' >"${main}/.claude/story.json"
git -C "${main}" init -q && git -C "${main}" add . \
  && git -C "${main}" -c user.name=t -c user.email=t@t commit -qm init \
  && git -C "${main}" worktree add -q "${tmp}/wt" 2>/dev/null
printf '{"checkpointPercent": 90}\n' >"${tmp}/wt/.claude/story.json"
t="$(transcript wt 400000 claude-opus-5-5)"
out="$(ptu s-wt "${t}" | env -u CLAUDE_CODE_HOST_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u STORY_CONFIG \
  STORY_PLANS_DIR="${plans}" CLAUDE_PROJECT_DIR="${tmp}/wt" "${hooks}/context-guard.sh" 2>"${tmp}/stderr")"
[[ "${out}" == *additionalContext* ]] && pass "config: a worktree session reads .claude/story.json of the main checkout" \
  || fail "config: the guard read the worktree .claude/story.json, not the main checkout's" "${out}"
mkdir -p "${main}/.plans"
printf '# q\n\n## Review\n' >"${main}/.plans/q.md"
out="$(jq -cn '{hook_event_name:"PostToolUse",session_id:"pb-wt",tool_name:"Bash",tool_input:{command:"true"}}' \
  | env -u CLAUDE_CODE_HOST_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u STORY_PLANS_DIR CLAUDE_PROJECT_DIR="${tmp}/wt" TMPDIR="${tmp}" \
    "${hooks}/plan-boundary.sh")"
[[ "${out}" == *"${main}/.plans/q.md"* ]] && pass "plan-boundary: a worktree session finds the plans of the main checkout" \
  || fail "plan-boundary: a worktree session missed the main checkout .plans" "${out}"

# 4c. no registered hook sets the session title. The desktop app ignores a
# hook's title output (live check E0c, 2026-10-27); the orchestrator removes
# its own ❗ or ⛔ with set_session_title. The pattern is a bracket class so
# that this file does not match itself.
title_hooks() { # title_hooks <hooks.json> <plugin root>: prints each hook that sets the title
  jq -r '.hooks // {} | to_entries[] | .key as $e | .value[].hooks[]? | select(.type == "command") | "\($e)\t\(.command)"' "$1" \
  | while IFS=$'\t' read -r e c; do
      c="${c#\"\$\{CLAUDE_PLUGIN_ROOT\}}"
      f="$2${c%\"}"
      [ -f "${f}" ] || { printf '%s hook %s is not a file\n' "${e}" "${f}"; continue; }
      grep -q 'session[T]itle' "${f}" 2>/dev/null && printf '%s hook %s sets the session title\n' "${e}" "${f}"
    done
}
o="$(title_hooks "${hooks}/hooks.json" "${repo}")"
[ -z "${o}" ] && pass "title: no registered hook sets the session title" || fail "title: a hook sets the session title, or names no file" "${o}"
mkdir -p "${tmp}/tproj/hooks"
printf '#!/bin/sh\njq -cn %s\n' "'{hookSpecificOutput:{hookEventName:\"UserPromptSubmit\",session$(printf T)itle:\"x\"}}'" >"${tmp}/tproj/hooks/t.sh"
printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\\"${CLAUDE_PLUGIN_ROOT}/hooks/t.sh\\""}]}]}}\n' >"${tmp}/tproj/hooks.json"
o="$(title_hooks "${tmp}/tproj/hooks.json" "${tmp}/tproj")"
[[ "${o}" == *"sets the session title"* ]] && pass "title: a UserPromptSubmit hook that sets the title fails" || fail "title: a title-setting hook passed" "$(cat "${tmp}/tproj/hooks/t.sh" "${tmp}/tproj/hooks.json") ${o}"

# 4d. one emoji map: /story holds it; briefs, /checkpoint and CLAUDE.md agree
map_check() { # map_check <map file> <file>...: exit 1 on a shared emoji, a shared token or a wrong pairing
  perl -CSD -e '
    use strict; my ($map, @files) = @ARGV; my (%e2t, %t2e, $bad);
    open my $m, "<:encoding(UTF-8)", $map or die "no map $map\n";
    while (<$m>) {
      next unless /^\|\s*(\p{So})\x{FE0F}?\s*\|\s*(?:`([A-Z][A-Z ]*[A-Z])`|-)\s*\|/;
      my ($e, $t) = ($1, $2 // "-");
      if (exists $e2t{$e}) { print "shared emoji $e\n"; $bad = 1 }
      $e2t{$e} = $t;
      next if $t eq "-";
      if (exists $t2e{$t}) { print "shared token $t\n"; $bad = 1 }
      $t2e{$t} = $e;
    }
    die "map $map has fewer than 13 rows\n" if keys(%e2t) < 13;
    my $alt = join "|", sort { length($b) <=> length($a) } map { quotemeta } keys %t2e;
    for my $f (@files) {
      open my $h, "<:encoding(UTF-8)", $f or die "no file $f\n";
      local $/; my $s = <$h>;
      while ($s =~ /(\p{So})\x{FE0F}?\s*`?($alt)\b/g) {
        next if $t2e{$2} eq $1;
        print "$f: $1 names $2, the map says $t2e{$2}\n"; $bad = 1;
      }
    }
    exit($bad ? 1 : 0);
  ' "$@"
}
story="${repo}/skills/story"
# A repo's CLAUDE.md that names the title states, like the one of Team EIFFEL - LEAN.
printf -- '- Session titles show the state: one emoji per status token, never shared. The orchestrator removes its own ❗ or ⛔ with `set_session_title`. A child ends with 🔍 `DOCKET` or 📦 `READY TO PUSH`.\n' >"${tmp}/CLAUDE.md"
map_check "${story}/SKILL.md" "${story}"/briefs/*.md "${repo}/skills/checkpoint/SKILL.md" "${tmp}/CLAUDE.md" >"${tmp}/map.out" 2>&1 \
  && pass "map: one emoji per state, and every brief agrees" || fail "map: the emoji map is not consistent" "$(cat "${tmp}/map.out")"
for f in "${story}"/briefs/*.md "${repo}/skills/checkpoint/SKILL.md"; do
  grep -q '💾 `CHECKPOINT`' "${f}" && pass "map: $(basename "${f}") carries its title states" || fail "map: $(basename "${f}") names no title state"
done
protocol_missing() { # protocol_missing <map file> <protocol line>: prints each child token of the map that the line does not name
  awk -F'|' 'NF > 5 && $3 ~ /`[A-Z]/ && $5 !~ /orchestrator/ { t = $3; gsub(/[ `]/, "", t); print t }' "$1" \
    | while IFS= read -r t; do printf '%s' "$2" | tr -d ' ' | grep -qF "${t}" || printf 'missing %s\n' "${t}"; done
}
line="$(. "${hooks}/story-lib.sh"; story_protocol_line)"
o="$(protocol_missing "${story}/SKILL.md" "${line}")"
[ -z "${o}" ] && pass "map: the re-prime protocol line names every child token" || fail "map: story_protocol_line in story-lib.sh misses a child token" "${o}"
o="$(protocol_missing "${story}/SKILL.md" "${line//PHASE DONE/}")"
[ "${o}" = "missing PHASEDONE" ] && pass "map: a protocol line without PHASE DONE fails" || fail "map: a protocol line without PHASE DONE passed" "${o}"
printf 'Set the title to 📦 `PLAN READY`.\n' >"${tmp}/wrong-brief.md"
map_check "${story}/SKILL.md" "${tmp}/wrong-brief.md" >/dev/null 2>&1 && fail "map: a wrong pairing passed" || pass "map: a wrong pairing fails"
sed 's/^| 🔀 |/| 📦 |/' "${story}/SKILL.md" >"${tmp}/dup-map.md"
map_check "${tmp}/dup-map.md" >/dev/null 2>&1 && fail "map: a shared emoji passed" || pass "map: a shared emoji fails"

# 4e. phased turns: every brief has a phase list, PHASE DONE and stop-and-redirect
phase_check() { # phase_check <brief>: exit 1 with the reason when a rule is missing
  awk '
    /^## / { in_p = ($0 == "## Phases"); if (in_p) seen = 1; next }
    in_p && /^\{\{PHASES\}\}$/ { items++ }
    in_p && /^[0-9]+\. / {
      items++; n = gsub(/#([0-9]+|\{\{[A-Z_]+\}\})/, "&")
      if (n != 1) { print "phase line names " n " task ids: " $0; bad = 1 }
    }
    /PHASE DONE #/ { done = 1 }
    /\*\*Stop and redirect\.\*\*/ && /stop_session/ { stop = 1 }
    END {
      if (!seen) { print "no ## Phases section"; bad = 1 }
      else if (!items) { print "## Phases lists no phase"; bad = 1 }
      if (!done) { print "names no PHASE DONE #<task>"; bad = 1 }
      if (!stop) { print "no stop-and-redirect rule"; bad = 1 }
      exit bad
    }' "$1"
}
for f in "${story}"/briefs/*.md; do
  phase_check "${f}" >"${tmp}/phase.out" && pass "phases: $(basename "${f}") has a phase list, PHASE DONE and stop-and-redirect" \
    || fail "phases: $(basename "${f}") breaks the phased-turn rules" "$(cat "${tmp}/phase.out")"
done
sed '/^## Phases$/,/^## /{/^## Rules/!d;}' "${story}/briefs/plan.md" >"${tmp}/no-phases.md"
phase_check "${tmp}/no-phases.md" >/dev/null && fail "phases: a brief without a phase list passed" || pass "phases: a brief without a phase list fails"
sed 's/^{{PHASES}}$//' "${story}/briefs/implement.md" >"${tmp}/empty-phases.md"
phase_check "${tmp}/empty-phases.md" >/dev/null && fail "phases: an empty phase list passed" || pass "phases: an empty phase list fails"
sed 's/^1\. `#{{PLAN_TASK}}` Draft\./1. Draft./' "${story}/briefs/plan.md" >"${tmp}/no-task.md"
phase_check "${tmp}/no-task.md" >/dev/null && fail "phases: a phase without a task id passed" || pass "phases: a phase without a task id fails"
grep -v 'Stop and redirect' "${story}/briefs/pr-review.md" >"${tmp}/no-stop.md"
phase_check "${tmp}/no-stop.md" >/dev/null && fail "phases: a brief without stop-and-redirect passed" || pass "phases: a brief without stop-and-redirect fails"
awk '/^\{\{PHASES\}\}$/ { print "1. #578 Hooks. Done when: the matrix is green."; print "2. #582 Review. Done when: DOCKET."; next } { print }' \
  "${story}/briefs/implement.md" >"${tmp}/filled.md"
phase_check "${tmp}/filled.md" >"${tmp}/phase.out" && pass "phases: a filled implement brief passes" || fail "phases: a filled implement brief failed" "$(cat "${tmp}/phase.out")"
grep -q '^## Phased turns and steering$' "${story}/SKILL.md" && grep -q 'stop_session' "${story}/SKILL.md" \
  && pass "phases: /story carries the phased-turn rules" || fail "phases: /story has no phased-turn rules"

# 5. pre-compact and post-compact
bind s-pc implement story-p
long_state "${plans}/story-p.d/implement.md"
t="$(transcript pc 380000 claude-opus-5-5)"
hook pre-compact.sh "$(jq -cn --arg t "${t}" '{hook_event_name:"PreCompact",session_id:"s-pc",trigger:"auto",transcript_path:$t}')"; o="${out}"
[ -z "${o}" ] && [ "${code}" -eq 0 ] && pass "pre-compact: prints nothing and exits 0" || fail "pre-compact: output or exit ${code}" "${o}"
grep -q 'CHECKPOINT-READY' "${plans}/story-p.d/compact/"implement-*-state.md 2>/dev/null && grep -q $'\tauto\t380000\t' "${plans}/story-p.d/compact/log.tsv" \
  && pass "pre-compact: copies the state and logs trigger and tokens" || fail "pre-compact: no copy or no log line"
hook pre-compact.sh 'not json'; o="${out}"
[ -z "${o}" ] && [ "${code}" -eq 0 ] && pass "pre-compact: a bad input still exits 0 silently" || fail "pre-compact: bad input exit ${code}" "${o}"
hook post-compact.sh '{"hook_event_name":"PostCompact","session_id":"s-pc","trigger":"plugin","compact_summary":"SUMMARY-MARKER"}'; o="${out}"
grep -l "SUMMARY-MARKER" "${plans}/story-p.d/compact/"implement-*.md >/dev/null 2>&1 && [ "${code}" -eq 0 ] \
  && pass "post-compact: writes the summary file" || fail "post-compact: no summary file"

# 5b. fail loud: a failed step leaves a line in <plans>/.sessions/<key>.log
bind s-pf implement story-f
long_state "${plans}/story-f.d/implement.md"
mkdir -p "${plans}/story-f.d/compact" && chmod 500 "${plans}/story-f.d/compact"
hook pre-compact.sh "$(jq -cn '{hook_event_name:"PreCompact",session_id:"s-pf",trigger:"auto"}')"; o="${out}"
[ -z "${o}" ] && [ "${code}" -eq 0 ] && grep -q 'pre-compact: cannot copy' "${plans}/.sessions/s-pf.log" 2>/dev/null \
  && pass "pre-compact: a failed state copy writes a log line, silent and exit 0" || fail "pre-compact: a failed copy left no log line" "$(cat "${plans}/.sessions/s-pf.log" 2>&1)"
hook post-compact.sh '{"hook_event_name":"PostCompact","session_id":"s-pf","trigger":"auto","compact_summary":"S"}'; o="${out}"
[ -z "${o}" ] && [ "${code}" -eq 0 ] && grep -q 'post-compact: cannot write' "${plans}/.sessions/s-pf.log" 2>/dev/null \
  && pass "post-compact: a failed summary write writes a log line" || fail "post-compact: a failed write left no log line" "$(cat "${plans}/.sessions/s-pf.log" 2>&1)"
chmod 700 "${plans}/story-f.d/compact"
mkdir -p "${tmp}/nojq"
for c in bash dirname cat grep; do ln -s "$(command -v "${c}")" "${tmp}/nojq/${c}"; done
t="$(transcript nojq 360000 claude-opus-5-5)"
hook context-guard.sh "$(ptu s-nojq "${t}")" PATH="${tmp}/nojq"
[ -z "${out}" ] && [ "${code}" -eq 0 ] && pass "guard: without jq a tool call stays silent and exits 0" || fail "guard: without jq PostToolUse printed or failed" "code ${code}, out: ${out}"
hook context-guard.sh "$(stop s-nojq "${t}")" PATH="${tmp}/nojq"
[ "${code}" -eq 0 ] && [ "$(jq -r '.systemMessage // empty' <<<"${out}" 2>/dev/null)" != "" ] && [[ "${out}" == *'jq is not on PATH'* ]] \
  && pass "guard: without jq Stop prints a systemMessage for the user" || fail "guard: without jq Stop printed no systemMessage" "code ${code}, out: ${out}"
hook role-guard.sh "$(guard_in g-implement Bash 'git push')" PATH="${tmp}/nojq"
[ "${code}" -eq 1 ] && grep -q 'jq is not on PATH' "${tmp}/stderr" \
  && pass "role-guard: without jq it names jq and exits 1" || fail "role-guard: without jq the reason is wrong" "code ${code}, stderr: $(cat "${tmp}/stderr")"
hook role-guard.sh "$(guard_in g-implement mcp__ccd_session_mgmt__clear_session g-other)" PATH="${tmp}/nojq"
[ "${code}" -eq 0 ] && [[ "${out}" == *'"permissionDecision":"ask"'* ]] && [[ "${out}" == *'jq is not on PATH'* ]] \
  && pass "role-guard: without jq a clear_session asks" || fail "role-guard: without jq a clear_session passed with no decision" "code ${code}, out: ${out}"

# story-bind. sbx runs it with the fixture config, a fixture HOME and a
# fixture project, so the settings of the machine never count.
home="${tmp}/home"
sbproj="${tmp}/sbproj"
mkdir -p "${home}/.claude" "${sbproj}/.claude" && git -C "${sbproj}" init -q
printf '{"autoCompactWindow": 1000000}\n' >"${home}/.claude/settings.json"
printf '{"autoCompactWindow": 432000}\n' >"${sbproj}/.claude/settings.json"
sbx() { # sbx [KEY=VALUE ...] -- <story-bind args>
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  env -u CLAUDE_CODE_HOST_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u CLAUDE_CONFIG_DIR \
    STORY_PLANS_DIR="${plans}" STORY_CONFIG="${tmp}/config.json" HOME="${home}" CLAUDE_PROJECT_DIR="${sbproj}" \
    STORY_MANAGED_DIR="${tmp}/no-managed" STORY_MANAGED_PLIST="${tmp}/no-managed.plist" \
    ${vars[@]+"${vars[@]}"} "${hooks}/story-bind.sh" "$@"
}
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-1 -- implement story-z --parent local_orch 2>&1 </dev/null)"
[ "$(jq -r '.role + "/" + .slug + "/" + .parent' "${plans}/.sessions/cli-1.json" 2>/dev/null)" = "implement/story-z/local_orch" ] && [ -d "${plans}/story-z.d" ] \
  && pass "story-bind: writes the binding under the session id" || fail "story-bind: binding wrong" "${o}"
o="$(sbx CLAUDE_CODE_HOST_SESSION_ID=local_h9 CLAUDE_CODE_SESSION_ID=cli-9 -- plan story-z 2>&1)"
[ -f "${plans}/.sessions/local_h9.json" ] && pass "story-bind: prefers the host id as the key" || fail "story-bind: host id not used" "${o}"
sbx CLAUDE_CODE_SESSION_ID=cli-2 -- boss story-z >/dev/null 2>&1
[ $? -eq 1 ] && pass "story-bind: an unknown role exits 1" || fail "story-bind: unknown role accepted"
sbx -- plan story-z >/dev/null 2>&1
[ $? -eq 1 ] && pass "story-bind: no session id exits 1" || fail "story-bind: bound without a session id"
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-1 -- --state)"
[ "${o}" = "${plans}/story-z.d/implement.md" ] && pass "story-bind: --state prints the bound checkpoint path" || fail "story-bind: --state wrong" "${o}"
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-free -- --state)"
[ "${o}" = "${plans}/.sessions/cli-free.md" ] && pass "story-bind: --state prints the unbound checkpoint path" || fail "story-bind: unbound --state wrong" "${o}"
bind cli-u implement story-u
for m in crossed nudged blocked; do printf '1\n' >"${plans}/.sessions/cli-u.${m}"; done
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-u -- --unbind 2>&1)"
left="$(find "${plans}/.sessions" -name 'cli-u.*')"
[ "${o}" = "Unbound cli-u." ] && [ -z "${left}" ] \
  && pass "story-bind: --unbind removes the binding and its marks" || fail "story-bind: --unbind left files" "${o}; ${left}"
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-u -- --unbind 2>&1)"; c=$?
[ "${c}" -eq 0 ] && [ "${o}" = "cli-u was not bound." ] && pass "story-bind: --unbind again exits 0" || fail "story-bind: a second --unbind failed" "${c} ${o}"
bind cli-child implement story-u
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-orch -- --unbind cli-child 2>&1)"
[ ! -e "${plans}/.sessions/cli-child.json" ] && pass "story-bind: --unbind <key> removes a child's binding" || fail "story-bind: --unbind <key> kept the binding" "${o}"
hook session-reprime.sh '{"hook_event_name":"SessionStart","source":"clear","session_id":"cli-child"}'
[ -z "${out}" ] && pass "story-bind: an unbound session gets no re-prime" || fail "story-bind: re-prime after --unbind" "${out}"

# story-bind fails loud without .claude/story.json (a command, not an automatic hook)
for args in "implement story-nc" "--state" "--show" "--unbind" "--check"; do
  # shellcheck disable=SC2086 # args holds several words on purpose
  o="$(sbx STORY_CONFIG="${tmp}/absent/story.json" CLAUDE_CODE_SESSION_ID=cli-nc -- ${args} 2>&1)"; c=$?
  [ "${c}" -eq 1 ] && [[ "${o}" == *"${tmp}/absent/story.json"* && "${o}" == *story.example.json* ]] && [ ! -e "${plans}/.sessions/cli-nc.json" ] \
    && pass "story-bind: ${args} without .claude/story.json exits 1 and names the file and story.example.json" \
    || fail "story-bind: ${args} without .claude/story.json: exit ${c}" "${o}"
done
printf '{"checkpointPercent": 35,}\n' >"${tmp}/broken.json"
o="$(sbx STORY_CONFIG="${tmp}/broken.json" CLAUDE_CODE_SESSION_ID=cli-nc -- implement story-nc 2>&1)"; c=$?
[ "${c}" -eq 1 ] && [[ "${o}" == *"${tmp}/broken.json"*"not valid JSON"* ]] && [ ! -e "${plans}/.sessions/cli-nc.json" ] \
  && pass "story-bind: a story.json that is not JSON exits 1 and names the file" || fail "story-bind: broken story.json: exit ${c}" "${o}"
o="$(sbx CLAUDE_CODE_SESSION_ID=cli-ck -- --check 2>&1)"; c=$?
[ "${c}" -eq 0 ] && [[ "${o}" == *"${tmp}/config.json"* ]] && [ ! -e "${plans}/.sessions/cli-ck.json" ] \
  && pass "story-bind: --check with a config exits 0, names it and binds nothing" || fail "story-bind: --check with a config: exit ${c}" "${o}"

# plan-boundary stays silent in a bound session
proj="${tmp}/proj"
mkdir -p "${proj}/.plans"
printf '# p\n\n## Review\n' >"${proj}/.plans/p.md"
pb_in() { jq -cn --arg s "$1" --arg f "${proj}/.plans/p.md" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Write",tool_input:{file_path:$f}}'; }
o="$(printf '%s' "$(pb_in pb-free)" | env -u CLAUDE_CODE_HOST_SESSION_ID STORY_PLANS_DIR="${plans}" STORY_CONFIG="${tmp}/config.json" CLAUDE_PROJECT_DIR="${proj}" TMPDIR="${tmp}" "${hooks}/plan-boundary.sh")"
[[ "${o}" == *systemMessage* ]] && pass "plan-boundary: unbound still reminds" || fail "plan-boundary: unbound reminder gone" "${o}"
bind pb-bound plan story-pb
o="$(printf '%s' "$(pb_in pb-bound)" | env -u CLAUDE_CODE_HOST_SESSION_ID STORY_PLANS_DIR="${plans}" STORY_CONFIG="${tmp}/config.json" CLAUDE_PROJECT_DIR="${proj}" TMPDIR="${tmp}" "${hooks}/plan-boundary.sh")"
[ -z "${o}" ] && pass "plan-boundary: a bound session is silent" || fail "plan-boundary: bound session reminded" "${o}"
# planBoundary false or missing: plan-boundary is silent and lint-mark stamps nothing.
lm_in='{"hook_event_name":"PreToolUse","session_id":"pb-off","tool_name":"Bash","tool_input":{"command":"true"}}'
for cfg in '{"checkpointPercent": 35}' '{"checkpointPercent": 35, "planBoundary": false}' '{"planBoundary": "yes"}'; do
  printf '%s\n' "${cfg}" >"${tmp}/pb-cfg.json"
  rm -rf "${tmp}/pb-tmp" && mkdir -p "${tmp}/pb-tmp"
  printf '%s' "${lm_in}" | env STORY_CONFIG="${tmp}/pb-cfg.json" TMPDIR="${tmp}/pb-tmp" "${hooks}/lint-mark.sh"
  o="$(printf '%s' "$(pb_in pb-off)" | env -u CLAUDE_CODE_HOST_SESSION_ID STORY_PLANS_DIR="${plans}" STORY_CONFIG="${tmp}/pb-cfg.json" CLAUDE_PROJECT_DIR="${proj}" TMPDIR="${tmp}/pb-tmp" "${hooks}/plan-boundary.sh")"
  [ -z "${o}" ] && [ -z "$(listing "${tmp}/pb-tmp" -type f)" ] \
    && pass "plan-boundary: ${cfg} prints no reminder and writes no stamp" \
    || fail "plan-boundary: ${cfg} reminded or stamped" "out: ${o}; files: $(listing "${tmp}/pb-tmp" -type f)"
done
printf '{"planBoundary": true}\n' >"${tmp}/pb-cfg.json"
rm -rf "${tmp}/pb-tmp" && mkdir -p "${tmp}/pb-tmp"
printf '%s' "${lm_in}" | env STORY_CONFIG="${tmp}/pb-cfg.json" TMPDIR="${tmp}/pb-tmp" "${hooks}/lint-mark.sh"
[ -f "${tmp}/pb-tmp/claude-lint-mark-pb-off" ] && pass "lint-mark: planBoundary true writes the stamp" || fail "lint-mark: planBoundary true wrote no stamp"

# 6. syntax and shellcheck
for f in "${hooks}"/*.sh "${repo}"/tests/*.sh; do
  bash -n "${f}" && pass "bash -n $(basename "${f}")" || fail "bash -n $(basename "${f}")"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -P "${hooks}" "${hooks}"/story-*.sh "${hooks}"/session-reprime.sh "${hooks}"/context-guard.sh \
    "${hooks}"/role-guard.sh "${hooks}"/pre-compact.sh "${hooks}"/post-compact.sh "${hooks}"/plan-boundary.sh \
    "${hooks}"/lint-mark.sh "${repo}"/tests/*.sh \
    && pass "shellcheck" || fail "shellcheck"
else
  printf 'skip shellcheck (not installed)\n'
fi

exit "${rc}"
