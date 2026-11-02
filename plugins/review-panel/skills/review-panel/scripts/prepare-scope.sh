#!/usr/bin/env bash
# Extract the exact review scope once, so every finder head reads the same
# bytes and nobody re-derives the diff: scope.md (refs, tree, file list),
# diff.patch, files.txt, a facts.md skeleton seeded with every pin found in
# the added lines, and an empty heads/ directory for head outputs.
# Usage: prepare-scope.sh <base-ref> <head-ref> [--pr <n>] [--out <dir>]
#        prepare-scope.sh --uncommitted [--out <dir>]   (working tree vs HEAD, untracked included)
#        prepare-scope.sh --plan <path> [--out <dir>]   (design review of one plan file, ignored files allowed)
# Also writes scope.env (MODE, BASE_SHA, HEAD_SHA, REPO, PATCH_SHA256): the
# runners derive their target from it and refuse a drifted checkout.
# Default out dir: .claude/.review/<head-short> (keep it gitignored). Prints the dir.
# The review profile of the repo (scripts/profile.sh) names the PR host for the
# sibling pull requests and the paths that count as the review harness.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git rev-parse --show-toplevel)"
cd "${repo}"
# shellcheck disable=SC1091
. "${here}/pins.sh"   # uncommitted_patch: same bytes here and in the runners' integrity check
# shellcheck disable=SC1091
. "${here}/profile.sh"
load_profile "${repo}" || exit 1
base="" head="" pr="" out="" uncommitted=0 plan=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --uncommitted) uncommitted=1; shift ;;
    --plan) plan="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) if [ -z "${base}" ]; then base="$1"; elif [ -z "${head}" ]; then head="$1"; else echo "unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done

mode="branch"
if [ -n "${plan}" ]; then
  [ -f "${plan}" ] || { echo "FAIL: plan file ${plan} not found" >&2; exit 1; }
  mode="plan"; head_sha="$(git rev-parse HEAD)"; base_sha="${head_sha}"; merge_base="${head_sha}"
  label="plan-$(basename "${plan%.md}")"
elif [ "${uncommitted}" = 1 ]; then
  mode="uncommitted"; head_sha="$(git rev-parse HEAD)"; base_sha="${head_sha}"; merge_base="${head_sha}"
  label="uncommitted-$(git rev-parse --short HEAD)"
else
  [ -n "${base}" ] && [ -n "${head}" ] || { echo "usage: prepare-scope.sh <base-ref> <head-ref> [--pr n] [--out dir] | --uncommitted" >&2; exit 2; }
  base_sha="$(git rev-parse --verify "${base}^{commit}")"
  head_sha="$(git rev-parse --verify "${head}^{commit}")"
  merge_base="$(git merge-base "${base_sha}" "${head_sha}")"
  label="$(git rev-parse --short "${head_sha}")"
fi
if [ -z "${out}" ]; then
  out=".claude/.review/${label}"
  git check-ignore -q "${out}/scope.md" \
    || echo "WARN: .claude/.review/ is not gitignored in this repo; add the line .claude/.review/ to .gitignore so a scope is never committed" >&2
fi
mkdir -p "${out}/heads"
out_abs="$(cd "${out}" && pwd)"

if [ "${mode}" = plan ]; then
  git diff --no-index -- /dev/null "${plan}" > "${out}/diff.patch" || true
  printf '%s\n' "${plan}" > "${out}/files.txt"
  stat="plan file $(wc -l < "${plan}" | tr -d ' ') lines"
elif [ "${uncommitted}" = 1 ]; then
  uncommitted_patch "${repo}" "${out_abs}" > "${out}/diff.patch"
  { git diff --name-only HEAD "${UNC_SPEC[@]}"; git ls-files --others --exclude-standard "${UNC_SPEC[@]}"; } | sort -u > "${out}/files.txt"
  stat="$(git diff --stat HEAD "${UNC_SPEC[@]}" | tail -1)"
else
  git diff "${merge_base}" "${head_sha}" > "${out}/diff.patch"
  git diff --name-only "${merge_base}" "${head_sha}" | sort > "${out}/files.txt"
  stat="$(git diff --stat "${merge_base}" "${head_sha}" | tail -1)"
fi
[ -s "${out}/diff.patch" ] || { echo "FAIL: empty diff for the requested scope (uncommitted work needs 'git add -N' for new files, or pass --uncommitted; a plan file needs --plan)" >&2; exit 1; }
patch_sha="$(shasum -a 256 "${out}/diff.patch" | cut -d' ' -f1)"
{
  # scope.env is sourced as shell: quote values that can carry spaces (this repo path does).
  echo "MODE=${mode}"; echo "REPO=\"${repo}\""; echo "BASE_SHA=${base_sha}"; echo "HEAD_SHA=${head_sha}"
  echo "MERGE_BASE=${merge_base}"; echo "PATCH_SHA256=${patch_sha}"; [ -n "${plan}" ] && echo "PLAN=\"${plan}\""; [ -n "${pr}" ] && echo "PR=${pr}"
} > "${out}/scope.env"

tree="$(git rev-parse "${head_sha}^{tree}")"
{
  echo "# Review scope"
  echo
  echo "- repo: ${repo}"
  echo "- mode: ${mode}"
  echo "- base: ${base:-HEAD} (${base_sha})"
  echo "- head: ${head:-working tree} (${head_sha}); tree ${tree}"
  echo "- merge-base: ${merge_base}"
  [ -n "${pr}" ] && echo "- pull request: #${pr}"
  [ -n "${plan}" ] && echo "- plan file: ${plan}"
  echo "- prepared: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "- stat: ${stat}"
  echo
  echo "## Files ($(wc -l < "${out}/files.txt" | tr -d ' '))"
  echo
  sed 's/^/- /' "${out}/files.txt"
  echo
  # Rendered copies: a generated file that re-embeds a source file already in
  # scope costs every head a second full read of the same bytes and yields
  # duplicate findings against the copy. Measured 2026-08-19: 760 of 3933 diff
  # lines were reconcile.py re-embedded in a ConfigMap.
  dupes="$(python3 - "${out}/diff.patch" <<'PY'
import collections, re, sys
added = collections.defaultdict(set)
path = None
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"^\+\+\+ b/(.*)$", line.rstrip("\n"))
    if m:
        path = m.group(1); continue
    if path and line.startswith("+") and not line.startswith("+++"):
        s = line[1:].strip()
        if len(s) > 12:
            added[path].add(s)
seen = set()
names = sorted(added)
for i, a in enumerate(names):
    for b in names[i + 1:]:
        la, lb = added[a], added[b]
        if len(la) < 50 or len(lb) < 50:
            continue
        if max(len(la & lb) / len(la), len(la & lb) / len(lb)) < 0.8:
            continue
        # The rendered artifact is the generated copy; naming the wrong one
        # would tell every head to skip the source file. Fall back to the
        # superset, which is the one embedding the other.
        if "/rendered/" in a and "/rendered/" not in b:
            copy, src = a, b
        elif "/rendered/" in b and "/rendered/" not in a:
            copy, src = b, a
        else:
            copy, src = (a, b) if len(la) >= len(lb) else (b, a)
        if (copy, src) in seen:
            continue
        seen.add((copy, src))
        print(f"- `{copy}` is a generated copy of `{src}`: review the source, not the copy")
PY
)"
  if [ -n "${dupes}" ]; then
    echo "## Duplicated content (do not report findings against the copy)"
    echo
    printf '%s\n' "${dupes}"
    echo
  fi
  # Open sibling pull requests: a finding that a dependency is "missing from
  # base branch" is a false positive when a sibling PR supplies it. Best effort;
  # the PR host CLI may be absent or unauthenticated, and a scope must still be
  # preparable.
  case "${PR_HOST}" in
    azure-repos)
      siblings="$(az repos pr list --status active --query '[].[pullRequestId, sourceRefName, title]' -o tsv 2>/dev/null \
          | awk -F'\t' 'NF{sub(/^refs\/heads\//, "", $2); printf "- !%s `%s`: %s\n", $1, $2, $3}' || true)"
      reader="az repos" ;;
    github)
      # shellcheck disable=SC2016 # the jq program is single-quoted on purpose
      siblings="$(gh pr list --state open --limit 50 --json number,headRefName,title \
          --jq '.[] | "- #\(.number) `\(.headRefName)`: \(.title)"' 2>/dev/null || true)"
      reader="gh" ;;
    *) siblings="" reader="" ;;
  esac
  if [ -n "${siblings}" ]; then
    echo "## Open sibling pull requests (context, not scope)"
    echo
    printf '%s\n' "${siblings}"
    echo
    echo "A dependency absent from ${BASE_REF} may be supplied by one of these. Check before reporting it missing."
    echo
  else
    echo "## Open sibling pull requests"
    echo
    if [ -n "${reader}" ]; then
      echo "Not available (no ${reader} access, not authenticated, or none open). A cross-branch dependency cannot be ruled out from this scope alone."
    else
      echo "Not looked up (the PR host is not GitHub or Azure Repos, or the review profile sets prHost none). A cross-branch dependency cannot be ruled out from this scope alone."
    fi
    echo
  fi
  echo "Finders read diff.patch for content and facts.md for every pinned-dependency fact. Report findings only against the file list above."
  echo
  echo "Reading is wider than reporting. Read precedent at the reviewed tree with \`git show <head>:<path>\` and \`git grep <pattern> <head>\`, where <head> is the head SHA above. Never read precedent from the worktree: it can carry uncommitted edits in files outside this list, and this review is bound to the recorded tree. Read an established sibling in full when the claim is that this change omits an invariant the sibling enforces. The precedent that proves an omission usually sits in a file this change does not touch. Read \`scope.md\`, \`facts.md\`, \`diff.patch\` and \`files.txt\` from the scope directory named above, and nothing else in it. Never open another scope directory under \`.claude/.review/\`: those hold orchestrator working files."
} > "${out}/scope.md"

# Pins in the ADDED lines: digests, versions, tags, chart/image refs. Verify live, date it, fill the facts section.
{
  echo "# Fact sheet (orchestrator fills before the heads run; heads cite it, never re-fetch)"
  echo
  echo "## Pins found in added lines (verify against the live source, write the verdict and date below)"
  echo
  grep -E '^\+' "${out}/diff.patch" | grep -v '^+++' \
    | grep -oE '([A-Za-z0-9._/:-]+@sha256:[0-9a-f]{64}|sha256:[0-9a-f]{64}|[A-Za-z0-9._/-]+@[0-9a-f]{40}|[A-Za-z0-9_]*(SHA256|DIGEST|CHECKSUM)[A-Za-z0-9_]*[:= ]+"?[0-9a-f]{64}"?|[A-Za-z0-9._-]+==[0-9][A-Za-z0-9.+-]*|[A-Za-z0-9._/-]+/[A-Za-z0-9._-]+:v?[0-9]+\.[0-9]+[A-Za-z0-9._-]*|(version|tag|chart|targetRevision|appVersion|VERSION)[":= ]+"?v?[0-9]+\.[0-9]+[A-Za-z0-9.+-]*"?)' \
    | sort -u | sed 's/^/- [ ] /' || true
  echo
  echo "## Verified facts (what, where checked, as of YYYY-MM-DD)"
  echo
  echo "- "
  echo
  echo "## Fact-sheet gaps (finders append a line when a load-bearing claim has no fact here; the arbiter resolves)"
  echo
} > "${out}/facts.md"

hits="$(harness_hits "${out}/files.txt")"
if [ -n "${hits}" ]; then
  echo "WARN: the candidate changes the review harness itself ($(wc -l <<< "${hits}" | tr -d ' ') files: $(tr '\n' ' ' <<< "${hits}")): read those hunks first; the profile and the repo rules the finders read come from this checkout" >&2
  echo "HARNESS_CHANGED=1" >> "${out}/scope.env"
fi
echo "${out_abs}"
echo "scope: $(wc -l < "${out}/files.txt" | tr -d ' ') files, $(wc -l < "${out}/diff.patch" | tr -d ' ') diff lines, tree ${tree:0:12}; fill facts.md before run-heads.sh" >&2
