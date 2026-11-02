#!/usr/bin/env bash
# Default finder of the review panel: one Codex adversarial review through the
# codex plugin's companion runtime (the same engine as /codex:adversarial-review,
# which only the user can invoke by name), with the panel's focus text rendered
# from heads/_focus.md and the repo's review profile against a prepared scope
# directory. Writes <scope>/adversarial.focus.md (the rendered focus),
# adversarial.json (structured findings) and adversarial.log.
# Usage: run-adversarial.sh <scope-dir> [--model <m>]
# The review target comes from <scope>/scope.env: branch mode reviews
# BASE_SHA..HEAD, uncommitted mode the working tree; plan mode is not a git
# target, use run-heads.sh. Before Codex starts, the manifest is verified
# (diff.patch digest, checkout at HEAD_SHA, scoped files clean in branch
# mode, working tree unchanged in uncommitted mode) and the companion and codex versions are checked against
# scripts/pins.sh; after it returns, the target the engine reports must
# match the manifest. REVIEW_PANEL_COMPANION overrides the companion path
# (tests). Codex effort is whatever ~/.codex/config.toml configures. Exit 1
# on any refusal or failed run.
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(git rev-parse --show-toplevel)"
scope="" model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) if [ -z "${scope}" ]; then scope="$1"; else echo "unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "${scope}" ] && [ -d "${scope}" ] || { echo "usage: run-adversarial.sh <scope-dir> (run prepare-scope.sh first)" >&2; exit 2; }
scope="$(cd "${scope}" && pwd)"
# shellcheck disable=SC1091
. "${skill_dir}/scripts/pins.sh"
# shellcheck disable=SC1091
. "${skill_dir}/scripts/profile.sh"
check_scope_integrity "${scope}" "${repo}" || exit 1
load_profile "${repo}" || exit 1
case "${MODE}" in
  branch) kind="branch"; base="${BASE_SHA}" ;;
  uncommitted) kind="working-tree"; base="" ;;   # --base would win over --scope working-tree (lib/git.mjs resolveReviewTarget): never pass it here
  plan) echo "FAIL: plan mode is not a git target for the adversarial engine; run run-heads.sh <scope> (plan heads: ${PLAN_HEADS})" >&2; exit 2 ;;
  *) echo "FAIL: scope.env MODE=${MODE} not understood" >&2; exit 1 ;;
esac

# shellcheck disable=SC2012 # the plugin cache path holds no odd names; sort -V picks the newest version
companion="${REVIEW_PANEL_COMPANION:-$(ls -d "${HOME}"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1 || true)}"
[ -n "${companion}" ] && [ -f "${companion}" ] \
  || { echo "FAIL: codex plugin companion not found under ~/.claude/plugins/cache/openai-codex (install the codex plugin: /plugin marketplace openai-codex)" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH (the companion runtime is a node script)" >&2; exit 1; }
command -v codex >/dev/null 2>&1 || { echo "FAIL: codex CLI not on PATH" >&2; exit 1; }
companion_version="$(basename "$(dirname "$(dirname "${companion}")")")"
codex_version="$(codex --version 2>/dev/null | head -1 | sed -E 's/^codex-cli //')"
check_pin "codex plugin companion" "${companion_version}" "${SUPPORTED_COMPANION_VERSIONS}" || exit 1
check_pin "codex CLI" "${codex_version}" "${SUPPORTED_CODEX_VERSIONS}" || exit 1

verified="$(awk '/^## Verified facts/{f=1;next} /^## /{f=0} f && !/^- ?$/ && NF' "${scope}/facts.md" | wc -l | tr -d ' ')"
[ "${verified}" -gt 0 ] || echo "WARN: facts.md 'Verified facts' is empty; Codex will report fact-sheet gaps instead of grounded claims" >&2

render_prompt "${scope}/adversarial.focus.md" "SCOPE_DIR=${scope}" -- "${skill_dir}/heads/_focus.md" || exit 1
focus="$(cat "${scope}/adversarial.focus.md")"
args=(adversarial-review --wait --json --scope "${kind}")
[ -n "${base}" ] && args+=(--base "${base}")
[ -n "${model}" ] && args+=(--model "${model}")
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "codex adversarial review: companion ${companion_version} (codex-cli ${codex_version}), mode ${MODE}, base ${base:0:12}, head ${HEAD_SHA:0:12}, started ${started}; output ${scope}/adversarial.json" >&2
if (cd "${repo}" && node "${companion}" "${args[@]}" "${focus}" > "${scope}/adversarial.json" 2> "${scope}/adversarial.log"); then
  python3 - "${scope}/adversarial.json" "${kind}" "${base}" <<'PY' || { echo "FAIL: adversarial.json rejected (see above and adversarial.log)" >&2; exit 1; }
import json, sys
d = json.load(open(sys.argv[1])); want_mode, want_base = sys.argv[2], sys.argv[3]
rev = d.get("result") or {}
tgt = d.get("target") or {}
print(f"target reported by the engine: {json.dumps(tgt)[:300]}", file=sys.stderr)
# branch: the companion echoes --base verbatim as baseRef (lib/git.mjs resolveReviewTarget, verified 2026-08-19 against 1.0.6 and a live run);
# working-tree: it reports no baseRef at all, so any baseRef means a different target was reviewed.
if tgt.get("mode") != want_mode or (want_base and tgt.get("baseRef") != want_base) or (not want_base and tgt.get("baseRef")):
    print(f"FAIL: engine reviewed target mode={tgt.get('mode')} base={tgt.get('baseRef')} but the scope manifest is mode={want_mode} base={want_base or '(working tree, no baseRef)'}; findings do not describe the prepared scope", file=sys.stderr); sys.exit(1)
if not rev:
    print(f"no structured result (parseError: {d.get('parseError')}); raw output kept in adversarial.json", file=sys.stderr); sys.exit(1)
findings = rev.get("findings") or []
print(f"verdict: {rev.get('verdict')}; findings: {len(findings)}; codex status: {(d.get('codex') or {}).get('status')}; summary: {str(rev.get('summary',''))[:200]}")
PY
  echo "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
else
  echo "FAIL: adversarial review exited non-zero; see ${scope}/adversarial.log" >&2; exit 1
fi
