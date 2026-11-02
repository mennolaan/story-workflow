#!/usr/bin/env bash
# Proves every suggestion block in a review docket replaces exactly
# the lines it is anchored to. Anchor = the one backticked `path:N` or
# `path:N-M` token (repo-relative path) on the non-blank line immediately
# before the ```suggestion fence; the lines are read from <head> with git
# show, so the check is against the reviewed tree, never the worktree. Prints, per block, the anchored lines and the replacement
# side by side for the judge to eyeball; fails loud on a block without an
# anchor, an anchor outside the file, an empty block, or a block whose
# lines all carry a common leading indent that the anchor lines do not
# (the usual symptom of a suggestion written inside a markdown list).
# Usage: check-docket.sh <docket.md> <head-ref>
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: check-docket.sh <docket.md> <head-ref>" >&2; exit 2; }
docket="$1" head="$2"
[ -f "${docket}" ] || { echo "FAIL: docket ${docket} not found" >&2; exit 1; }
git rev-parse --verify -q "${head}^{commit}" >/dev/null || { echo "FAIL: ${head} is not a commit in this repo" >&2; exit 1; }
python3 - "${docket}" "$(git rev-parse "${head}^{commit}")" <<'PY'
import re, subprocess, sys
def fail(msg):
    print(msg, file=sys.stderr)
docket, head = sys.argv[1], sys.argv[2]
# Brackets, parentheses, @ and + are Next.js route segments: [id], [...path], (group), @slot.
anchor_re = re.compile(r"`([A-Za-z0-9_./@+()\[\]-]+):(\d+)(?:-(\d+))?`")
lines = open(docket).read().split("\n")
blocks = 0; bad = 0; i = 0
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
print(f"{blocks} suggestion block(s), {bad} defect(s)")
sys.exit(1 if bad or blocks == 0 else 0)
PY
