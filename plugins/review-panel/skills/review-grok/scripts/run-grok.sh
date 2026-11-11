#!/usr/bin/env bash
# Finder runner of /review-grok: Grok reviews one scope that
# review-panel/scripts/prepare-scope.sh prepared, read-only, in the reviewed tree.
# Default mode: one adversarial review, prompts/no-shell.md plus
#   prompts/adversarial.md plus review-panel/heads/_focus.md, bound to
#   schemas/findings.schema.json and checked by validate-findings.py. Writes
#   <scope>/grok.prompt.md, findings.grok.json and findings.grok.log.
# Deep mode (--deep, and always for a plan scope): the review-panel stance
#   heads, prompts/no-shell.md plus review-panel/heads/_preamble.md plus
#   heads/<head>.md. Writes <scope>/heads/<head>.grok.{prompt.md,out.md,log}
#   and heads/status.grok.tsv.
# Usage: run-grok.sh <scope-dir> --default|--deep [--heads a,b,c] [--focus <text>] [--max-parallel <n>] [--timeout <minutes>] [--effort <e>] [--model <m>] [--dry-run]
# --default or --deep is the depth the user chose (step 3 of review-panel
# SKILL.md); without one the runner exits 2. A plan scope always runs the heads
# and needs no depth flag.
# A run below 8 turns prints `WARN: thin sample (N turns, below 8); consider a
# second run or --deep`; the judge copies that line into the docket.
# Heads default to deepHeads of the review profile (else the seven of
# review-panel: delivery dependency identity parity situate reach falsify),
# and to planHeads (delivery,conform,situate) for a plan.
# At most 3 heads run at once (--max-parallel; the subscription rate limits
# are not measured). Every Grok run stops after --timeout minutes (default 30)
# or 40 turns, and then fails with no output. The scope manifest is verified
# first, grok.sh preflight runs one probe turn, and check_tree_untouched
# proves afterwards that nothing was written. Exit 1 on a refusal or any
# failed run; the other outputs stay usable.
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel_dir="$(cd "${skill_dir}/../review-panel" && pwd)"
repo="$(git rev-parse --show-toplevel)"
scope="" deep=0 depth="" heads="" focus="" max_parallel=3 timeout_min=30 effort="" model="" dry=0
THIN_TURNS=8
while [ $# -gt 0 ]; do
  case "$1" in
    --deep) deep=1; depth=deep; shift ;;
    --default) depth=default; shift ;;
    --heads) heads="$2"; shift 2 ;;
    --focus) focus="$2"; shift 2 ;;
    --max-parallel) max_parallel="$2"; shift 2 ;;
    --timeout) timeout_min="$2"; shift 2 ;;
    --effort) effort="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) if [ -z "${scope}" ]; then scope="$1"; else echo "unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "${scope}" ] && [ -d "${scope}" ] || { echo "usage: run-grok.sh <scope-dir> (run review-panel/scripts/prepare-scope.sh first)" >&2; exit 2; }
case "${max_parallel}" in *[!0-9]*|""|0) echo "FAIL: --max-parallel ${max_parallel} is not a positive whole number" >&2; exit 2 ;; esac
case "${timeout_min}" in *[!0-9]*|""|0) echo "FAIL: --timeout ${timeout_min} is not a positive whole number of minutes" >&2; exit 2 ;; esac
case "${effort}" in
  ""|none|minimal|low|medium|high|xhigh|max) ;;
  *) echo "FAIL: --effort ${effort} is not a reasoning effort; use none, minimal, low, medium, high, xhigh or max" >&2; exit 2 ;;
esac
scope="$(cd "${scope}" && pwd)"
schema="${skill_dir}/schemas/findings.schema.json"
# shellcheck disable=SC1091
. "${skill_dir}/scripts/lib.sh"
# shellcheck disable=SC1091
. "${panel_dir}/scripts/profile.sh"
check_scope_integrity "${scope}" "${repo}" || exit 1
[ -n "${depth}" ] || [ "${MODE}" = plan ] || { echo "FAIL: choose the depth (--default or --deep); the skill asks the user first" >&2; exit 2; }
if [ "${depth}" = default ] && [ "${deep}" = 1 ]; then echo "FAIL: --default and --deep exclude each other" >&2; exit 2; fi
load_profile "${repo}" || exit 1
if [ "${MODE}" = plan ]; then deep=1; depth=plan; fi
if [ "${deep}" = 1 ] && [ -z "${heads}" ]; then
  if [ "${MODE}" = plan ]; then heads="${PLAN_HEADS}"; else heads="${DEEP_HEADS}"; fi
fi
[ "${deep}" = 1 ] || [ -z "${heads}" ] || { echo "FAIL: --heads needs --deep (default mode runs one adversarial review)" >&2; exit 2; }
if [ "${dry}" = 1 ]; then "${skill_dir}/scripts/grok.sh" preflight --static || exit 1
else "${skill_dir}/scripts/grok.sh" preflight || exit 1; fi

verified="$(awk '/^## Verified facts/{f=1;next} /^## /{f=0} f && !/^- ?$/ && NF' "${scope}/facts.md" | wc -l | tr -d ' ')"
[ "${verified}" -gt 0 ] || echo "WARN: facts.md 'Verified facts' is empty; Grok will report fact-sheet gaps instead of grounded claims" >&2
grok_version="$("${skill_dir}/scripts/grok.sh" version)"
tree="<reviewed tree>"
if [ "${dry}" = 0 ]; then
  tree="$(reviewed_tree "${repo}")" || exit 1
  trap 'remove_reviewed_tree "${repo}" "${tree}"' EXIT
fi
echo "review-grok: grok ${grok_version}, mode ${MODE}, $([ "${deep}" = 1 ] && echo "heads ${heads}" || echo "adversarial"), head ${HEAD_SHA:0:12}, timeout ${timeout_min} min, reviewed tree ${tree}" >&2

# Grok cannot run git log, so the runner writes the recent commits that touch the scoped files.
recent="${scope}/grok-recent-commits.txt" recent_ref="${BASE_REF}"
git -C "${repo}" rev-parse --verify --quiet "${recent_ref}" >/dev/null || recent_ref="HEAD"
scoped=()
while IFS= read -r f; do [ -n "${f}" ] && scoped+=("${f}"); done < "${scope}/files.txt"
{ echo "# git log --oneline -20 ${recent_ref} -- <the ${#scoped[@]} scoped files>"
  git -C "${repo}" log --oneline -20 "${recent_ref}" -- ${scoped[@]+"${scoped[@]}"} 2>/dev/null || true
} > "${recent}"
# Placeholders of prompts/no-shell.md; render_prompt replaces them in every Grok prompt.
grok_vars=("TREE=${tree}" "RECENT=${recent}" "RECENT_REF=${recent_ref}" "SCOPE_DIR=${scope}")
# turns_of <log>: num_turns from the meta line that grok.sh run writes first into the log, or empty.
turns_of() {
  python3 - "$1" <<'TURNS' 2>/dev/null || true
import json, sys
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if isinstance(d, dict) and "num_turns" in d:
        print(d["num_turns"] if isinstance(d["num_turns"], int) else ""); break
TURNS
}
# thin_sample <label> <turns>: the WARN line for a run below THIN_TURNS turns. A short run gives
# findings (or none) that look as strong as a full read.
thin_sample() {
  case "$2" in ""|*[!0-9]*) return 0 ;; esac
  [ "$2" -lt "${THIN_TURNS}" ] && echo "WARN: thin sample ($2 turns, below ${THIN_TURNS}); consider a second run or --deep${1:+ (${1})}" >&2
  return 0
}
opts=(--timeout "$((timeout_min * 60))")
[ -n "${model}" ] && opts+=(--model "${model}")
[ -n "${effort}" ] && opts+=(--effort "${effort}")
rc=0

if [ "${deep}" = 0 ]; then
  prompt="${scope}/grok.prompt.md" out="${scope}/findings.grok.json" log="${scope}/findings.grok.log"
  render_prompt "${prompt}" "${grok_vars[@]}" "REPO=${repo}" \
    -- "${skill_dir}/prompts/no-shell.md" "${skill_dir}/prompts/adversarial.md" "${panel_dir}/heads/_focus.md" || exit 1
  [ -z "${focus}" ] || printf '\nFocus from the requester: %s\n' "${focus}" >> "${prompt}"
  rm -f "${out}"
  if [ "${dry}" = 1 ]; then "${skill_dir}/scripts/grok.sh" run "${prompt}" "${out}" "${log}" "${tree}" "${opts[@]}" --schema "${schema}" --dry-run; exit 0; fi
  if "${skill_dir}/scripts/grok.sh" run "${prompt}" "${out}" "${log}" "${tree}" "${opts[@]}" --schema "${schema}"; then
    turns="$(turns_of "${log}")"
    write_finder_env "${scope}" grok "grok ${grok_version}" default "${turns}"
    thin_sample "" "${turns}"
    if count="$(python3 "${skill_dir}/scripts/validate-findings.py" "${schema}" "${out}")"; then
      echo "grok: ${count} findings in ${out}"
    else
      rc=1; echo "FAIL: the result does not match ${schema}; the findings do not reach the judge" >&2
    fi
  else
    rc=1; echo "FAIL: the grok review failed; see ${log}" >&2
  fi
else
  render() {  # render <head>: the review-panel head behind the no-shell note and the review-panel preamble
    local head="$1" parts=()
    while IFS= read -r f; do parts+=("${f}"); done < <(head_parts "${head}")
    [ "${#parts[@]}" -gt 0 ] || return 1
    # __REPO__ in the no-shell note is the shared checkout (for ignored files); in the preamble it is the
    # reviewed tree, so the note is rendered on its own first.
    render_prompt "${scope}/heads/${head}.grok.prompt.md" "${grok_vars[@]}" "REPO=${repo}" -- "${skill_dir}/prompts/no-shell.md" || return 1
    render_prompt "${scope}/heads/${head}.grok.body.md" "SCOPE_DIR=${scope}" "REPO=${tree}" "TRIGGER_LABEL=$(trigger_label "${head}")" \
      -- "${panel_dir}/heads/_preamble.md" "${parts[@]}" || return 1
    { echo; cat "${scope}/heads/${head}.grok.body.md"; } >> "${scope}/heads/${head}.grok.prompt.md"
    rm -f "${scope}/heads/${head}.grok.body.md"
  }
  IFS=',' read -r -a head_list <<< "${heads}"
  for head in "${head_list[@]}"; do render "${head}" || exit 1; done
  for head in "${head_list[@]}"; do
    h="${scope}/heads/${head}.grok"
    rm -f "${h}.out.md" "${h}.status"
    if [ "${dry}" = 1 ]; then "${skill_dir}/scripts/grok.sh" run "${h}.prompt.md" "${h}.out.md" "${h}.log" "${tree}" "${opts[@]}" --dry-run; continue; fi
    # The slot wait polls `jobs`, because the macOS system bash (3.2) has no `wait -n`.
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "${max_parallel}" ]; do sleep 2; done
    (
      t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if "${skill_dir}/scripts/grok.sh" run "${h}.prompt.md" "${h}.out.md" "${h}.log" "${tree}" "${opts[@]}"; then st=0; else st=$?; fi
      printf '%s\t%s\t%s\n' "${st}" "${t0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${h}.status"
    ) &
  done
  wait
  [ "${dry}" = 1 ] && exit 0
  printf 'head\texit\tbytes\tstarted\tfinished\tturns\n' > "${scope}/heads/status.grok.tsv"
  all_turns=""
  for head in "${head_list[@]}"; do
    h="${scope}/heads/${head}.grok"
    st="missing" t0="" t1="" bytes=0 turns=""
    [ -f "${h}.status" ] && IFS=$'\t' read -r st t0 t1 < "${h}.status"
    [ -f "${h}.out.md" ] && bytes="$(wc -c < "${h}.out.md" | tr -d ' ')"
    [ -f "${h}.log" ] && turns="$(turns_of "${h}.log")"
    [ "${st}" = 0 ] && [ "${bytes}" -gt 0 ] || { rc=1; echo "FAIL head ${head}: exit ${st}, ${bytes} bytes; see ${h}.log" >&2; }
    [ "${st}" = 0 ] && thin_sample "head ${head}" "${turns}"
    all_turns="${all_turns:+${all_turns},}${head}:${turns:-?}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${head}" "${st}" "${bytes}" "${t0}" "${t1}" "${turns}" >> "${scope}/heads/status.grok.tsv"
  done
  write_finder_env "${scope}" grok "grok ${grok_version}" "${depth}" "${all_turns}"
  cat "${scope}/heads/status.grok.tsv" >&2
fi

check_tree_untouched "${repo}" "${scope}" "${tree}" || rc=1
[ "${rc}" = 0 ] && echo "review-grok complete: ${scope}" || echo "review-grok finished with failures (rc=1); usable outputs listed above" >&2
exit "${rc}"
