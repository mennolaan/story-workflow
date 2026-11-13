#!/usr/bin/env bash
# Checks a review docket before it is presented. The docket must carry a
# `checks:` line: the checks that ran for this review with their result, or
# `checks: author claim, not verified in this review` when none could run.
# Proves every suggestion block in it replaces exactly the lines it is
# anchored to. Anchor = the one backticked `path:N` or `path:N-M` token
# (repo-relative path) on the non-blank line immediately before the
# ```suggestion fence; the lines are read from <head> with git show, so the
# check is against the reviewed tree, never the worktree. Prints, per block,
# the anchored lines and the replacement side by side for the judge to
# eyeball; fails loud on a block without an anchor, an anchor outside the
# file, an empty block, or a block whose lines all carry a common leading
# indent that the anchor lines do not (the usual symptom of a suggestion
# written inside a markdown list). A docket with no suggestion block (a clean
# result, or findings without one) passes on the checks line alone.
# With --scope <scope-dir> it also writes <scope>/verdict.json, the record of
# the review: PR id and status, head SHA and tree, depth, finder, version and
# turns (from the runner's finder.env), findings, survivors, verdict and date.
# The docket must then carry `verdict: <approved | approved with comments |
# author decides | fix before merge>` and `findings: <N> raised, <M> survived`,
# and <head> must be the scope head. A PR review needs this record:
# .claude/.last-review.json binds to the checkout's tree, not the PR's.
# Usage: check-docket.sh <docket.md> <head-ref> [--scope <scope-dir>]
set -euo pipefail
docket="" head="" scope=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) [ $# -ge 2 ] || { echo "usage: check-docket.sh <docket.md> <head-ref> [--scope <scope-dir>]" >&2; exit 2; }; scope="$2"; shift 2 ;;
    *) if [ -z "${docket}" ]; then docket="$1"; elif [ -z "${head}" ]; then head="$1"; else echo "usage: check-docket.sh <docket.md> <head-ref> [--scope <scope-dir>]" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "${docket}" ] && [ -n "${head}" ] || { echo "usage: check-docket.sh <docket.md> <head-ref> [--scope <scope-dir>]" >&2; exit 2; }
[ -f "${docket}" ] || { echo "FAIL: docket ${docket} not found" >&2; exit 1; }
git rev-parse --verify -q "${head}^{commit}" >/dev/null || { echo "FAIL: ${head} is not a commit in this repo" >&2; exit 1; }
if [ -n "${scope}" ]; then
  [ -f "${scope}/scope.env" ] || { echo "FAIL: ${scope}/scope.env not found; --scope takes the scope dir of this review" >&2; exit 1; }
  scope="$(cd "${scope}" && pwd)"
fi
python3 - "${docket}" "$(git rev-parse "${head}^{commit}")" "${scope}" <<'PY'
import datetime, json, os, re, shlex, subprocess, sys
def fail(msg):
    print(msg, file=sys.stderr)
docket, head, scope = sys.argv[1], sys.argv[2], sys.argv[3]
# Brackets, parentheses, @ and + are Next.js route segments: [id], [...path], (group), @slot.
anchor_re = re.compile(r"`([A-Za-z0-9_./@+()\[\]-]+):(\d+)(?:-(\d+))?`")
# A header line: `checks: ...`, `- checks: ...` or `**checks:** ...`.
def header(name):
    rx = re.compile(r"^\s*(?:[-*]\s+)?(?:\*\*)?" + name + r"(?:\*\*)?\s*:(?:\*\*)?\s*(\S.*)$", re.I)
    for l in lines:
        m = rx.match(l)
        if m:
            return m.group(1).strip()
    return None
lines = open(docket).read().split("\n")
blocks = 0; bad = 0; i = 0
if header("checks") is None:
    fail("FAIL: the docket has no `checks:` line; name the checks that ran for this review and their result, or write `checks: author claim, not verified in this review`"); bad += 1
def file_lines(path):
    r = subprocess.run(["git", "show", f"{head}:{path}"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout.split("\n")
while i < len(lines):
    line = lines[i]
    if line.strip() == "```suggestion":
        blocks += 1
        j = i + 1; body = []
        while j < len(lines) and lines[j].strip() != "```":
            body.append(lines[j]); j += 1
        k = i - 1
        while k >= 0 and not lines[k].strip():
            k -= 1
        found = anchor_re.findall(lines[k]) if k >= 0 else []
        anchor = (found[0][0], int(found[0][1]), int(found[0][2] or found[0][1]), k + 1) if len(found) == 1 else None
        if anchor is None:
            fail(f"FAIL: suggestion block at docket line {i+1}: the line before it must carry exactly one `path:N[-M]` anchor (found {len(found)})"); bad += 1
        else:
            path, a, b, at = anchor
            src = file_lines(path)
            if src is None:
                fail(f"FAIL: anchor `{path}:{a}-{b}` (docket line {at}): {path} is not in {head[:12]}"); bad += 1
            elif a < 1 or b < a or b > len(src) - 1:
                fail(f"FAIL: anchor `{path}:{a}-{b}` (docket line {at}) is outside the file (1-{len(src)-1})"); bad += 1
            elif not body or all(not l.strip() for l in body):
                fail(f"FAIL: suggestion for `{path}:{a}-{b}` is empty"); bad += 1
            else:
                old = src[a-1:b]
                indent = min((len(l) - len(l.lstrip()) for l in body if l.strip()), default=0)
                old_indent = min((len(l) - len(l.lstrip()) for l in old if l.strip()), default=0)
                print(f"== `{path}:{a}-{b}` replaces {b-a+1} line(s) with {len(body)}")
                for l in old: print(f"   - {l}")
                for l in body: print(f"   + {l}")
                if indent > old_indent and indent > 0 and not any(l.startswith(" " * indent) for l in old):
                    fail(f"FAIL: every replacement line is indented by {indent} while the anchored lines are not: the block was written inside a markdown list; re-emit it at column 0"); bad += 1
        i = j
    i += 1
if scope and not bad:
    def env(path):
        out = {}
        if os.path.isfile(path):
            for raw in open(path):
                raw = raw.strip()
                if "=" in raw and not raw.startswith("#"):
                    k, v = raw.split("=", 1)
                    out[k] = " ".join(shlex.split(v)) if v else ""
        return out
    s, f = env(os.path.join(scope, "scope.env")), env(os.path.join(scope, "finder.env"))
    verdicts = ("approved", "approved with comments", "author decides", "fix before merge")
    verdict = (header("verdict") or "").strip("*` .").lower()
    counts = re.match(r"^(\d+)\D+(\d+)", header("findings") or "")
    if s.get("HEAD_SHA") != head:
        fail(f"FAIL: the docket was checked against {head[:12]} but the scope head is {s.get('HEAD_SHA', '')[:12]}"); bad += 1
    if verdict not in verdicts:
        fail(f"FAIL: the docket needs a `verdict:` line with one of: {', '.join(verdicts)} (found {verdict or 'none'})"); bad += 1
    if not counts:
        fail("FAIL: the docket needs a `findings: <N> raised, <M> survived` line"); bad += 1
    if not bad:
        tree = subprocess.run(["git", "rev-parse", f"{head}^{{tree}}"], capture_output=True, text=True).stdout.strip()
        turns = f.get("TURNS") or None
        record = {"pr": s.get("PR") or None, "pr_status": s.get("PR_STATUS") or None, "mode": s.get("MODE"),
                  "head": head, "tree": tree, "depth": f.get("DEPTH") or None, "finder": f.get("FINDER") or None,
                  "finder_version": f.get("FINDER_VERSION") or None,
                  "turns": int(turns) if turns and turns.isdigit() else turns,
                  "findings": int(counts.group(1)), "survivors": int(counts.group(2)), "verdict": verdict,
                  "checks": header("checks"), "date": datetime.date.today().isoformat()}
        with open(os.path.join(scope, "verdict.json"), "w") as out:
            json.dump(record, out, indent=2); out.write("\n")
        print(f"verdict.json: {os.path.join(scope, 'verdict.json')} ({verdict}; {record['findings']} raised, {record['survivors']} survived)")
print(f"{blocks} suggestion block(s), {bad} defect(s)")
sys.exit(1 if bad else 0)
PY
