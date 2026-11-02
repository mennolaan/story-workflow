#!/usr/bin/env python3
"""Render one finder prompt of the review panel.

Usage: render.py --out <file> [--context <context.md>] [--set KEY=VALUE]... -- <part>...
Joins the parts with one blank line between them. Replaces __CONTEXT__ with the
profile context (or the default context when the file is absent), then each
__KEY__ with its value. A profile part (a file under the profile folder) is
headed with one line that names it as project detail. Fails on a missing part
and on a placeholder that is still unreplaced.
"""
import argparse
import os
import re
import sys

DEFAULT_CONTEXT = (
    "Repo rules that bind the diff: read CLAUDE.md and AGENTS.md at the repo root when they exist, "
    "and the decision record, architecture and known-issues documents they name. A rule they state "
    "binds the change; an accepted trade-off they record is not a finding."
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--context", default="")
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("parts", nargs="+")
    a = ap.parse_args()
    profile_dir = os.path.dirname(os.path.realpath(a.context)) if a.context else ""
    chunks = []
    for part in a.parts:
        if not os.path.isfile(part):
            print(f"FAIL: prompt part {part} not found", file=sys.stderr)
            return 1
        text = open(part).read().rstrip("\n")
        if profile_dir and os.path.realpath(part).startswith(profile_dir + os.sep):
            text = "Project detail for this head, from the review profile of the repo:\n\n" + text
        chunks.append(text)
    body = "\n\n".join(chunks) + "\n"
    if a.context and os.path.isfile(a.context):
        context = "Project context, from the review profile of the repo:\n\n" + open(a.context).read().strip()
    else:
        context = DEFAULT_CONTEXT
    body = body.replace("__CONTEXT__", context)
    for kv in a.set:
        key, sep, value = kv.partition("=")
        if not sep or not re.fullmatch(r"[A-Z_]+", key):
            print(f"FAIL: --set {kv} is not KEY=VALUE", file=sys.stderr)
            return 2
        body = body.replace(f"__{key}__", value)
    left = sorted(set(re.findall(r"__[A-Z][A-Z_]*[A-Z]__", body)))
    if left:
        print(f"FAIL: {a.out}: placeholders left unreplaced: {', '.join(left)}", file=sys.stderr)
        return 1
    with open(a.out, "w") as f:
        f.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
