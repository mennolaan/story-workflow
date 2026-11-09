#!/usr/bin/env bash
# Run the review-panel finder heads on Codex, in parallel, read-only, against
# one prepared scope directory. Renders heads/<name>.md behind the shared
# preamble into <scope>/heads/<name>.prompt.md, runs `codex exec` per head,
# writes <name>.out.md (final message), <name>.log (events) and status.tsv.
# Usage: run-heads.sh <scope-dir> [--heads a,b,c] [--effort <none|minimal|low|medium|high|xhigh|max>] [--model gpt-6.1-sol] [--dry-run]
# Heads default to deepHeads of the review profile, else the seven: delivery
# dependency identity parity situate reach falsify. conform, daytwo,
# invariants and ux stay in the library and are selected explicitly; a plan
# scope defaults to planHeads (delivery,conform,situate). A head file in the
# profile is appended to the generic head of that name, or stands alone. See
# SKILL.md.
# Deep/plan finder heads require gpt-6.1-sol explicitly; never inherit a model
# from ~/.codex/config.toml or fall back to an older Sol/Astra model. Effort
# defaults to ~/.codex/config.toml. `codex exec` does NOT
# validate this value: it echoes an unknown one back into the header and runs
# anyway, so a typo would silently change how the panel thinks. Validated here
# instead. Note `max` is accepted by the CLI but REJECTED by the plugin
# companion, so run-adversarial.sh can only reach max through the config file
# (companion 1.0.6 normalizeReasoningEffort, verified 2026-08-19).
# The scope manifest is verified first (scripts/pins.sh check_scope_integrity)
# and the codex version checked against the pin. Exit 1 on a refusal or if
# any head failed; the other outputs stay usable.
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(git rev-parse --show-toplevel)"
scope="" heads="" effort="" model="gpt-6.1-sol" dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --heads) heads="$2"; shift 2 ;;
    --effort) effort="$2"; shift 2 ;;
    --model)
      [ "${2:-}" = "gpt-6.1-sol" ] || { echo "FAIL: deep/plan review requires --model gpt-6.1-sol; other models and fallbacks are not allowed" >&2; exit 2; }
      model="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) if [ -z "${scope}" ]; then scope="$1"; else echo "unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "${scope}" ] && [ -d "${scope}" ] || { echo "usage: run-heads.sh <scope-dir> (run prepare-scope.sh first)" >&2; exit 2; }
case "${effort}" in
  ""|none|minimal|low|medium|high|xhigh|max) ;;
  *) echo "FAIL: --effort ${effort} is not a reasoning effort; use none, minimal, low, medium, high, xhigh or max. codex accepts an unknown value silently, so this would have run at an unintended effort" >&2; exit 2 ;;
esac
scope="$(cd "${scope}" && pwd)"
# shellcheck disable=SC1091
. "${skill_dir}/scripts/pins.sh"
# shellcheck disable=SC1091
. "${skill_dir}/scripts/profile.sh"
check_scope_integrity "${scope}" "${repo}" || exit 1
load_profile "${repo}" || exit 1
if [ -z "${heads}" ]; then
  if [ "${MODE}" = plan ]; then heads="${PLAN_HEADS}"; else heads="${DEEP_HEADS}"; fi
fi
command -v codex >/dev/null 2>&1 || { echo "FAIL: codex CLI not on PATH (the panel needs its cross-family stage)" >&2; exit 1; }
codex_version="$(codex --version 2>/dev/null | head -1 | sed -E 's/^codex-cli //')"
check_pin "codex CLI" "${codex_version}" "${SUPPORTED_HEAD_CODEX_VERSIONS}" || exit 1
verified="$(awk '/^## Verified facts/{f=1;next} /^## /{f=0} f && !/^- ?$/ && NF' "${scope}/facts.md" | wc -l | tr -d ' ')"
[ "${verified}" -gt 0 ] || echo "WARN: facts.md 'Verified facts' is empty; heads will report fact-sheet gaps instead of grounded claims" >&2
echo "codex heads: codex-cli ${codex_version}, mode ${MODE}, head ${HEAD_SHA:0:12}, heads ${heads}, model ${model}, effort ${effort:-config-default}" >&2

render() {  # render <head>
  # No finding cap: a stated maximum reads as a target. Measured 2026-08-19,
  # caps 10/10/12: the delivery and identity heads returned exactly 10 while
  # dependency returned 7 and situate 6. The preamble carries a quality bar
  # instead ("none" is a normal result; do not fill to a count).
  local head="$1" parts=()
  while IFS= read -r f; do parts+=("${f}"); done < <(head_parts "${head}") || return 1
  [ "${#parts[@]}" -gt 0 ] || return 1
  render_prompt "${scope}/heads/${head}.prompt.md" "SCOPE_DIR=${scope}" "REPO=${repo}" "TRIGGER_LABEL=$(trigger_label "${head}")" \
    -- "${skill_dir}/heads/_preamble.md" "${parts[@]}"
}

# model_reasoning_summary=auto: without it the header reads "reasoning summaries:
# none" and <head>.log records 4 lines of prose for 38 tool calls, so a head's
# deliberation cannot be audited after the fact. Key verified against codex-cli
# 0.146.0, 2026-08-19.
args=(exec --sandbox read-only -C "${repo}" --color never -m "${model}" -c model_reasoning_summary="auto")
[ -n "${effort}" ] && args+=(-c "model_reasoning_effort=\"${effort}\"")

IFS=',' read -r -a head_list <<< "${heads}"
pids=() names=()
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for head in "${head_list[@]}"; do
  render "${head}" || exit 1
  if [ "${dry}" = 1 ]; then echo "dry-run: codex ${args[*]} -o ${scope}/heads/${head}.out.md - < ${scope}/heads/${head}.prompt.md"; continue; fi
  ( codex "${args[@]}" -o "${scope}/heads/${head}.out.md" - < "${scope}/heads/${head}.prompt.md" > "${scope}/heads/${head}.log" 2>&1 ) &
  pids+=($!); names+=("${head}")
done
[ "${dry}" = 1 ] && exit 0

rc=0
{ echo -e "head\texit\tbytes\tstarted\tfinished"; } > "${scope}/heads/status.tsv"
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then st=0; else st=$?; rc=1; fi
  out="${scope}/heads/${names[$i]}.out.md"
  bytes=0; [ -f "${out}" ] && bytes="$(wc -c < "${out}" | tr -d ' ')"
  [ "${st}" = 0 ] && [ "${bytes}" -gt 0 ] || { rc=1; echo "FAIL head ${names[$i]}: exit ${st}, ${bytes} bytes; see ${scope}/heads/${names[$i]}.log" >&2; }
  printf '%s\t%s\t%s\t%s\t%s\n' "${names[$i]}" "${st}" "${bytes}" "${started}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${scope}/heads/status.tsv"
done
cat "${scope}/heads/status.tsv" >&2
[ "${rc}" = 0 ] && echo "heads complete: ${scope}/heads" || echo "heads finished with failures (rc=1); usable outputs listed above" >&2
exit "${rc}"
