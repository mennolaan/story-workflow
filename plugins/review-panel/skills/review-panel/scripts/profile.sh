#!/usr/bin/env bash
# The review profile of the repo under review: what the generic panel needs to
# know about one project. Sourced by prepare-scope.sh, run-adversarial.sh,
# run-heads.sh and the review-grok runner. Run directly to print it:
#   profile.sh show [<repo>]
#
# Location: ${REVIEW_PANEL_PROFILE:-<repo>/.claude/review-profile}. Every file is optional:
#   profile.json   name, baseRef, prHost (auto|azure-repos|github|none), harnessPaths
#                  (added to the defaults), deepHeads, planHeads. An unknown key fails loud.
#   context.md     project rules for every finder prompt, in place of __CONTEXT__.
#   judge.md       instructions for the judge (the main thread): checks, severity, PR threads.
#   heads/<h>.md   appended to the generic head <h>, or a head of its own when the plugin has none.
# load_profile <repo> sets PROFILE_DIR (empty when the folder is absent), PROFILE_NAME,
# BASE_REF, PR_HOST, HARNESS_PATHS (newline list), DEEP_HEADS and PLAN_HEADS.

PANEL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_SKILL="$(cd "${PANEL_SCRIPTS}/.." && pwd)"

load_profile() {
  local repo="$1" dir out
  dir="${REVIEW_PANEL_PROFILE:-${repo}/.claude/review-profile}"
  PROFILE_DIR=""
  [ -d "${dir}" ] && PROFILE_DIR="$(cd "${dir}" && pwd)"
  out="$(python3 - "${repo}" "${PROFILE_DIR}" <<'PY'
import json, os, shlex, subprocess, sys
repo, pdir = sys.argv[1], sys.argv[2]
keys = {"name": str, "baseRef": str, "prHost": str, "harnessPaths": list, "deepHeads": list, "planHeads": list}
d = {}
path = os.path.join(pdir, "profile.json") if pdir else ""
if path and os.path.isfile(path):
    try:
        d = json.load(open(path))
    except json.JSONDecodeError as exc:
        print(f"FAIL: {path} is not valid JSON: {exc}", file=sys.stderr); sys.exit(1)
    if not isinstance(d, dict):
        print(f"FAIL: {path} must hold one JSON object", file=sys.stderr); sys.exit(1)
    for k, v in d.items():
        if k not in keys:
            print(f"FAIL: {path}: unknown key '{k}'; known keys: {', '.join(keys)}", file=sys.stderr); sys.exit(1)
        if not isinstance(v, keys[k]) or (keys[k] is list and not all(isinstance(x, str) and x for x in v)):
            print(f"FAIL: {path}: '{k}' must be a {'list of strings' if keys[k] is list else 'string'}", file=sys.stderr); sys.exit(1)
def git(*a):
    r = subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""
base = d.get("baseRef") or ""
if not base:
    head = git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    base = head.replace("refs/remotes/", "", 1) if head else ""
    for cand in ("origin/main", "origin/master"):
        if not base and git("rev-parse", "--verify", "--quiet", cand):
            base = cand
    base = base or "HEAD"
host = d.get("prHost", "auto")
if host not in ("auto", "azure-repos", "github", "none"):
    print(f"FAIL: {path}: prHost '{host}' is not auto, azure-repos, github or none", file=sys.stderr); sys.exit(1)
if host == "auto":
    url = git("remote", "get-url", "origin")
    host = "github" if "github.com" in url else "azure-repos" if ("dev.azure.com" in url or "visualstudio.com" in url) else "none"
harness = [".claude/review-profile/", ".claude/settings.json", "CLAUDE.md", "AGENTS.md"]
if pdir:
    rel = os.path.relpath(os.path.realpath(pdir), os.path.realpath(repo))
    if not rel.startswith(".."):
        harness.append(rel.rstrip("/") + "/")
harness += [p for p in d.get("harnessPaths", []) if p not in harness]
deep = d.get("deepHeads") or ["delivery", "dependency", "identity", "parity", "situate", "reach", "falsify"]
plan = d.get("planHeads") or ["delivery", "conform", "situate"]
out = {"PROFILE_NAME": d.get("name") or os.path.basename(os.path.realpath(repo)), "BASE_REF": base, "PR_HOST": host,
       "HARNESS_PATHS": "\n".join(dict.fromkeys(harness)), "DEEP_HEADS": ",".join(deep), "PLAN_HEADS": ",".join(plan)}
for k, v in out.items():
    print(f"{k}={shlex.quote(v)}")
PY
)" || return 1
  eval "${out}"
}

# harness_hits <files.txt>: prints the scoped files that belong to the review harness
# (a HARNESS_PATHS entry that ends in / is a folder prefix, any other entry an exact path).
harness_hits() {
  local f p
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    while IFS= read -r p; do
      [ -n "${p}" ] || continue
      case "${p}" in
        */) case "${f}" in "${p}"*) echo "${f}"; break ;; esac ;;
        *) [ "${f}" = "${p}" ] && { echo "${f}"; break; } ;;
      esac
    done <<< "${HARNESS_PATHS}"
  done < "$1"
  return 0
}

# head_parts <head>: the prompt files of one head on stdout, one per line: the generic head of the
# plugin, then the profile addendum. Fails when neither exists.
head_parts() {
  local head="$1" found=0
  case "${head}" in ""|*/*|.*|_*) echo "FAIL: '${head}' is not a head name" >&2; return 1 ;; esac
  [ -f "${PANEL_SKILL}/heads/${head}.md" ] && { echo "${PANEL_SKILL}/heads/${head}.md"; found=1; }
  [ -n "${PROFILE_DIR}" ] && [ -f "${PROFILE_DIR}/heads/${head}.md" ] && { echo "${PROFILE_DIR}/heads/${head}.md"; found=1; }
  [ "${found}" = 1 ] || { echo "FAIL: unknown head '${head}': no ${PANEL_SKILL}/heads/${head}.md${PROFILE_DIR:+ and no ${PROFILE_DIR}/heads/${head}.md}" >&2; return 1; }
}

# trigger_label <head>: the label of the trigger line in the finding format.
trigger_label() {
  case "$1" in
    conform) echo "authority" ;;
    situate) echo "source" ;;
    parity)  echo "peer" ;;
    invariants) echo "invariant and reaching path" ;;
    ux) echo "design board" ;;
    *) echo "trigger (minimal privilege and state)" ;;
  esac
}

# render_prompt <out> <KEY=VALUE>... -- <file>...: joins the files, puts the profile context at
# __CONTEXT__ and replaces each __KEY__. See render.py.
render_prompt() {
  local out="$1" sets=()
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do sets+=(--set "$1"); shift; done
  [ "${1:-}" = -- ] || { echo "FAIL: render_prompt needs -- before the prompt files" >&2; return 2; }
  shift
  python3 "${PANEL_SCRIPTS}/render.py" --out "${out}" --context "${PROFILE_DIR:+${PROFILE_DIR}/context.md}" \
    --set "PROJECT=${PROFILE_NAME}" "${sets[@]}" -- "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  [ "${1:-}" = show ] || { echo "usage: profile.sh show [<repo>]" >&2; exit 2; }
  repo="${2:-$(git rev-parse --show-toplevel)}"
  load_profile "${repo}" || exit 1
  echo "profile: ${PROFILE_DIR:-none (defaults; add ${REVIEW_PANEL_PROFILE:-${repo}/.claude/review-profile} to tune the panel)}"
  echo "name: ${PROFILE_NAME}"
  echo "base ref: ${BASE_REF}"
  echo "pr host: ${PR_HOST}"
  echo "deep heads: ${DEEP_HEADS}"
  echo "plan heads: ${PLAN_HEADS}"
  echo "harness paths: $(tr '\n' ' ' <<< "${HARNESS_PATHS}")"
  for f in context.md judge.md; do
    if [ -n "${PROFILE_DIR}" ] && [ -f "${PROFILE_DIR}/${f}" ]; then echo "${f}: ${PROFILE_DIR}/${f}"; else echo "${f}: none"; fi
  done
  if [ -n "${PROFILE_DIR}" ] && [ -d "${PROFILE_DIR}/heads" ]; then
    echo "profile heads: $(find "${PROFILE_DIR}/heads" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort | tr '\n' ' ')"
  fi
fi
