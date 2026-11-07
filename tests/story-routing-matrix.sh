#!/usr/bin/env bash
# Integration cases for routing, safe grouping, budgets and precedence.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cfg="${tmp}/config.json"
manifest="${tmp}/routing.json"
printf '{"parallel":{"max":10}}\n' >"${cfg}"
cat >"${manifest}" <<'JSON'
{"tasks":[
 {"id":"1","profile":"retrieval","inputTokens":2000,"workTokens":3000,"reason":"extract specified wiki contract"},
 {"id":"2","profile":"implementation","inputTokens":10000,"workTokens":15000,"reason":"bounded feature"},
 {"id":"3","profile":"complex","inputTokens":10000,"workTokens":20000,"reason":"concurrency invariant"},
 {"id":"merge","profile":"implementation","inputTokens":5000,"workTokens":10000,"reason":"merge and checks"},
 {"id":"review","profile":"review","inputTokens":5000,"workTokens":10000,"reason":"judge findings"}
]}
JSON
rc=0
route() {
 out="$(env -u CLAUDE_CODE_EFFORT_LEVEL -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL \
   STORY_CONFIG="${cfg}" "$@" "${repo}/hooks/story-route.sh" "${args[@]}" 2>"${tmp}/stderr")"
 code=$?
}
ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n%s\n' "$1" "${out} $(cat "${tmp}/stderr")" >&2; rc=1; }
expect() {
 local label="$1" query="$2"; shift 2; route "$@"
 if [ "${code}" -eq 0 ] && jq -e "${query}" <<<"${out}" >/dev/null; then ok "${label}"; else fail "${label}"; fi
}
deny() {
 local label="$1" pattern="$2"; shift 2; route "$@"
 if [ "${code}" -ne 0 ] && grep -q "${pattern}" "${tmp}/stderr"; then ok "${label}"; else fail "${label}"; fi
}

args=(plan); expect 'planning remains Opus/high' '.model == "claude-opus-5-5" and .effort == "high"'
args=(pr-review); expect 'review starts Sonnet/high' '.family == "sonnet" and .effort == "high"'
args=(requirements-review); expect 'requirements review starts Sonnet/medium' '.role == "requirements-review" and .family == "sonnet" and .effort == "medium"'
args=(architect-review); expect 'conditional architecture review starts Sonnet/high' '.role == "architect-review" and .family == "sonnet" and .effort == "high"'
args=(requirements-review --profile complex --effort high); expect 'orchestrator can escalate a difficult requirements question' '.family == "opus" and .effort == "high" and (.reason|contains("complex"))'
args=(architect-review --profile review --effort medium); expect 'orchestrator can lower architecture effort independently of profile' '.family == "sonnet" and .effort == "medium" and (.reason|contains("effort override: medium"))'
args=(requirements-review --profile requirements --effort high); expect 'requirements can use more effort without upgrading model' '.family == "sonnet" and .effort == "high"'
args=(architect-review --profile complex --effort medium); expect 'architecture model and effort are independently selected' '.family == "opus" and .effort == "medium"'
deny 'specialist effective effort conflicts are refused' 'overrides medium' CLAUDE_CODE_EFFORT_LEVEL=max
deny 'specialist forced model conflicts are refused' 'forced subagent model' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=haiku
expect 'matching forced specialist model is allowed' '.family == "opus" and .effort == "medium"' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=opus
args=(requirements-review --profile typo); deny 'unknown specialist profile fails before launch' 'unknown specialist profile'
args=(architect-review --effort typo); deny 'unknown specialist effort fails before launch' 'unsupported specialist effort'
args=(architect-review --profile review --profile complex); deny 'duplicate profile cannot silently replace a decision' 'may appear only once'
args=(requirements-review --effort medium --effort high); deny 'duplicate effort cannot silently replace a decision' 'may appear only once'
args=(requirements-review --profile); deny 'missing specialist profile value fails' 'requires one nonempty value'
args=(architect-review --effort ''); deny 'empty specialist effort fails' 'requires one nonempty value'
args=(--profile requirements); deny 'specialist options without a role fail with usage on Bash 3.2' 'usage: story-route.sh'
args=(plan --profile review); deny 'specialist selection cannot accidentally downgrade the plan role' 'only for requirements-review'
args=(--check --effort high "${manifest}" "${manifest}"); deny 'specialist overrides cannot bypass preflight' 'only for requirements-review'
args=(requirements-review "${manifest}" 2); deny 'specialists cannot be mixed into implementation scope estimates' 'not implementation task estimates'
args=(verification); expect 'executing known tests is Haiku/low' '.family == "haiku" and .effort == "low"'
args=(implement-track "${manifest}" 1); expect 'retrieval-only track can stay Haiku' '.family == "haiku" and .effort == "low"'
args=(implement-track "${manifest}" 2); expect 'normal implementation uses Sonnet/medium' '.family == "sonnet" and .effort == "medium" and .estimatedContextTokens == 125000 and .sizing == "within-target" and .warnings == []'
args=(implement-track "${manifest}" '1,2,3'); expect 'mixed track selects strongest route and counts startup once' '.family == "opus" and .effort == "high" and .estimatedContextTokens == 160000'
args=(implement "${manifest}" 'merge,review'); expect 'story branch includes review effort and overhead' '.family == "sonnet" and .effort == "high" and .estimatedContextTokens == 130000'
args=(implement-track "${manifest}" 99); deny 'missing task cannot silently default to Opus' 'requested task missing'
args=(implement-track "${manifest}" '2,2'); deny 'duplicate selection cannot miscount scope' 'duplicate requested'
args=(implement-track); deny 'track cannot launch without estimates' 'requires task estimates'
args=(implement); deny 'story branch cannot launch without estimates' 'requires task estimates'
args=(implement-track "${manifest}" 2); deny 'environment cannot silently force max effort' 'overrides medium' CLAUDE_CODE_EFFORT_LEVEL=max
args=(reader); deny 'forced Opus subagents block cheap retrieval' 'forced subagent model' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=opus
expect 'matching forced Haiku permits retrieval' '.family == "haiku"' CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=haiku
args=(plan); expect 'matching effort environment is allowed' '.effort == "high"' CLAUDE_CODE_EFFORT_LEVEL=high

cp "${manifest}" "${tmp}/original.json"
jq '.tasks += [.tasks[0]]' "${tmp}/original.json" >"${manifest}"
args=(implement-track "${manifest}" 2); deny 'duplicate manifest ids fail' 'duplicate task id'
jq '.tasks[1].workTokens = 100000' "${tmp}/original.json" >"${manifest}"
expect 'oversized handoff advises splitting without blocking work' '.sizing == "consider-splitting" and (.warnings|length) == 1 and .compactionLikely == false'
jq '.tasks[1].workTokens = 300000' "${tmp}/original.json" >"${manifest}"
expect 'likely compaction is allowed and reported' '.sizing == "consider-splitting" and .compactionLikely == true and .family == "sonnet"'
jq '.tasks[1].workTokens = -1' "${tmp}/original.json" >"${manifest}"
deny 'negative estimates fail' 'positive workTokens'
jq '.tasks[1].profile = "typo"' "${tmp}/original.json" >"${manifest}"
deny 'unknown profiles fail' 'known profile'
cp "${tmp}/original.json" "${manifest}"
printf '{"routing":{"targetSessionTokens":150000,"startupTokens":20000,"profiles":{"implementation":{"effort":"low"}},"models":{"sonnet":{"id":"deployment-sonnet","window":200000}}}}\n' >"${cfg}"
expect 'provider override retains family and a model-specific target' '.model == "deployment-sonnet" and .effort == "low" and .sessionTargetTokens == 70000 and .estimatedContextTokens == 45000'
args=(requirements-review --profile requirements --effort high)
expect 'specialist routes honor provider ids and context windows' '.model == "deployment-sonnet" and .effort == "high" and .sessionTargetTokens == 70000 and .estimatedContextTokens == 20000'
printf '{"routing":{"profiles":{"requirements":{"family":"opus","effort":"high"}}}}\n' >"${cfg}"
args=(requirements-review); expect 'repo policy can override requirements defaults' '.family == "opus" and .effort == "high"'
args=(requirements-review --profile review --effort medium); expect 'explicit specialist selection can choose another configured profile' '.family == "sonnet" and .effort == "medium"'
args=(implement-track "${manifest}" 2)
printf '{"routing":{"models":{"sonnet":{"window":100000}}}}\n' >"${cfg}"
expect 'smaller context window warns about compaction without blocking' '.sessionTargetTokens == 35000 and .compactionLikely == true and .sizing == "consider-splitting"'
printf '{"backstopTokens":120000}\n' >"${cfg}"
expect 'earlier backstop affects the compaction warning' '.sessionTargetTokens == 102000 and .compactionLikely == true'
printf '{"routing":{"targetSessionTokens":50000}}\n' >"${cfg}"
expect 'startup above the target remains advisory' '.sessionTargetTokens == 50000 and .sizing == "consider-splitting"'
for bad in '{"routing":false}' '{"routing":{"profiles":false}}' '{"routing":{"profiles":{"unknown":{}}}}' '{"routing":{"targetSessionTokens":"200000"}}' '{"routing":{"startupTokens":false}}' '{"routing":{"profiles":{"implementation":{"effort":"typo"}}}}' '{"routing":{"modles":{}}}'; do
 printf '%s\n' "${bad}" >"${cfg}"
 deny "invalid config fails: ${bad}" 'routing failed'
done
printf '{"parallel":{"max":10}}\n' >"${cfg}"
cat >"${tmp}/plan.md" <<'PLAN'
## Order of work
| Task | Wave | Depends | Files | Track |
|---|---|---|---|---|
| #1 | T | - | wiki.txt | A |
| #2 | T | - | src/feature.ts | B |
| #3 | T | - | src/concurrency.ts | C |
PLAN
args=(--check "${tmp}/plan.md" "${manifest}")
route
if [ "${code}" -eq 0 ] && [ "$(jq -s length <<<"${out}")" -eq 4 ]; then ok 'preflight budgets each safe track plus story branch'; else fail 'safe group preflight'; fi
jq 'del(.tasks[1])' "${tmp}/original.json" >"${manifest}"
deny 'preflight catches a claim omitted from routing' 'cover exactly'
cp "${tmp}/original.json" "${manifest}"
# Each track fits, but dependency joins make a >200k group. Check the safe output.
jq '(.tasks[]|select(.id == "2" or .id == "3")|.workTokens)=45000' "${tmp}/original.json" >"${manifest}"
sed 's/| #3 | T | - |/| #3 | T | 2 |/' "${tmp}/plan.md" >"${tmp}/joined.md"
args=(--check "${tmp}/joined.md" "${manifest}"); expect 'dependency-joined tracks warn on their combined size' 'select(.tasks == ["2","3"]) | .sizing == "consider-splitting" and .estimatedContextTokens == 210000'
printf '{"parallel":{"max":1}}\n' >"${cfg}"
args=(--check "${tmp}/plan.md" "${manifest}"); expect 'sequential work can proceed with an aggregate sizing warning' '.role == "implement" and .sizing == "consider-splitting" and (.tasks|length) == 5'
# Shared-file moves accumulate on the story branch, not in separate estimates.
printf '{"parallel":{"max":10,"shared":["src/**"]}}\n' >"${cfg}"
expect 'shared-file moves contribute to the sizing warning' '.role == "implement" and .sizing == "consider-splitting"'
exit "${rc}"
