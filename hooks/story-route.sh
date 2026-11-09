#!/usr/bin/env bash
# Resolve a handoff's model, effort and estimated context before starting it.
# Usage: story-route.sh <plan|implement|implement-track|pr-review|reader|verification>
#                      [<routing.json> <task,task,...>]
#        story-route.sh <requirements-review|architect-review|documentation-review|requirements-verify>
#                      [--profile <profile>] [--effort <level>]
#        story-route.sh --check <plan.md> <routing.json>
# --check validates coverage and budgets using the safe groups, including moves
# and joins, from story-groups.sh. Sequential mode budgets the entire story.
# routing.json: {"tasks":[{"id":"101","profile":"implementation",
#   "inputTokens":10000,"workTokens":20000,"reason":"bounded API change"}]}
# Estimates describe peak context growth, NOT cumulative billed tokens.
# Sizing is advisory: exceeding the planning target warns but does not block.
# Exit 1: invalid input or conflicting environment. No writes.
# Bash 3.2 compatible; jq and git are already plugin requirements.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"
die() { printf 'story-route: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die 'jq is not on PATH.'
profile="" effort_override=""
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "${profile}" ] || die '--profile requires one nonempty value and may appear only once.'
      profile="$2"; shift 2 ;;
    --effort)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "${effort_override}" ] || die '--effort requires one nonempty value and may appear only once.'
      effort_override="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -gt 0 ] || die 'usage: story-route.sh <role> [<routing.json> <task,task,...>]'
set -- "${args[@]}"
[ "$#" -eq 1 ] || [ "$#" -eq 3 ] || die 'usage: story-route.sh <role> [<routing.json> <task,task,...>]'
case "$1" in
  requirements-review|architect-review|documentation-review|requirements-verify)
    [ "$#" -eq 1 ] || die 'specialist reviews accept --profile/--effort, not implementation task estimates.' ;;
  *)
    [ -z "${profile}${effort_override}" ] || die '--profile/--effort are only for requirements-review, architect-review, documentation-review and requirements-verify.' ;;
esac
cfg="$(story_config_file)"
[ -f "${cfg}" ] || die "missing ${cfg}."
if [ "$1" = --check ]; then
  [ "$#" -eq 3 ] && [ -f "$2" ] && [ -f "$3" ] || die 'usage: story-route.sh --check <plan.md> <routing.json>'
  groups="$("${here}/story-groups.sh" "$2")"; code=$?
  [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ] || die 'invalid claims table.'
  expected="$(awk '/^FOUNDATION |^INTEGRATE / {for(i=2;i<=NF;i++)print $i} /^TRACK / {for(i=3;i<=NF;i++)print $i}' <<<"${groups}" | jq -Rsc 'split("\n")|map(select(length>0))|sort')"
  jq -e --argjson expected "${expected}" '
    (.tasks|type == "array") and
    ((.tasks|map(.id)|sort) == ($expected + ["merge","review"]|sort)) and
    (($expected|index("merge")) == null) and (($expected|index("review")) == null)
  ' "$3" >/dev/null || die 'routing manifest must cover exactly the claims plus reserved merge/review overhead ids.'
  if [[ "${groups}" == *'MODE sequential'* ]]; then
    ids="$(jq -r '.tasks|map(.id)|join(",")' "$3")"
    "${here}/story-route.sh" implement "$3" "${ids}" || exit 1
  else
    while IFS= read -r ids; do
      [ -z "${ids}" ] || "${here}/story-route.sh" implement-track "$3" "${ids}" || exit 1
    done < <(awk '/^TRACK / {s=$3;for(i=4;i<=NF;i++)s=s "," $i;print s}' <<<"${groups}")
    ids="$(awk '/^FOUNDATION |^INTEGRATE / {for(i=2;i<=NF;i++)printf "%s,",$i} END {print "merge,review"}' <<<"${groups}")"
    "${here}/story-route.sh" implement "$3" "${ids}" || exit 1
  fi
  exit 0
fi
manifest='{"tasks":[]}'
if [ "$#" -eq 3 ]; then
  [ -f "$2" ] || die "no routing manifest: $2"
  manifest="$(cat "$2")"
fi
result="$(jq -en --slurpfile configs "${cfg}" --argjson manifest "${manifest}" \
  --arg role "$1" --arg ids "${3:-}" --arg profile "${profile}" --arg effort "${effort_override}" \
  -f "${here}/story-route.jq")" || die 'routing failed; fix the config or manifest before starting a session.'

# The environment outranks explicit effort, including subagent frontmatter.
effort="$(jq -r .effort <<<"${result}")"
if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] && [ "${CLAUDE_CODE_EFFORT_LEVEL}" != "${effort}" ]; then
  die "CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL} overrides ${effort}. Resolve the effective Desktop environment before launching."
fi
case "$1" in
  reader|verification|requirements-review|architect-review|documentation-review|requirements-verify)
    if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" ] && [ "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE}" != 0 ] && [ "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE}" != false ]; then
      forced="${CLAUDE_CODE_SUBAGENT_MODEL:-}"
      model="$(jq -r .model <<<"${result}")"
      family="$(jq -r .family <<<"${result}")"
      [ -z "${forced}" ] || [ "${forced}" = "${model}" ] || [ "${forced}" = "${family}" ] \
        || die "forced subagent model ${forced} overrides ${model}. Resolve it before launching."
    fi ;;
esac
jq -r '.warnings[] | "story-route: " + .' <<<"${result}" >&2
printf '%s\n' "${result}"
