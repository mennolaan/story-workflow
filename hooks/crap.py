#!/usr/bin/env python3
"""CRAP (Change Risk Anti-Patterns) for the functions a change touches.

    CRAP(f) = CC(f)^2 * (1 - cov(f))^3 + CC(f)

CC is cyclomatic complexity, cov the line coverage of the function in [0, 1].
A complex function with no tests scores high; full coverage leaves CC itself.
The classic threshold is 30: at CC 30 or more no coverage brings a function
under it, and with no coverage a CC of 5 already scores 30.

Usage:
  crap.py --base <sha> [--head <sha>] --coverage <file> [--coverage <file>...]
          [--complexity <lizard.csv>] [--threshold 30] [--all]
          [--format json|markdown] [--fail-over]

Complexity: Python files are measured here with the standard library (ast).
Other languages need a lizard CSV (`lizard --csv <paths> > lizard.csv`);
without one their changed files are listed as unmeasured, never scored 0.
Coverage: LCOV (vitest, jest, c8, coverage.py lcov) or Cobertura XML
(coverlet, coverage.py xml). Several files merge; a line counts as covered
when any report covers it. A changed function in a file no report mentions
gets coverage 0 and `coverageData: "none"`: missing coverage is not a pass.

Only functions whose lines the diff base..head touches are reported (all
functions with --all). The report is bound to base, head and the hashes of the
coverage files. Exit 0, or 2 with --fail-over when a function is over the
threshold. Standard library only.
"""
import argparse
import ast
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

CODE = {".py", ".cs", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".java", ".kt", ".go", ".rs",
        ".swift", ".rb", ".php", ".c", ".cc", ".cpp", ".h", ".hpp", ".scala", ".m", ".vue"}


def git(root, *args, check=True):
    result = subprocess.run(["git", "-c", "core.quotePath=false", *args], cwd=root,
                            capture_output=True, text=True)
    if check and result.returncode:
        raise SystemExit("crap: git " + " ".join(args) + " failed: " + result.stderr.strip())
    return result.stdout


def crap(cc, cov):
    return cc * cc * (1 - cov) ** 3 + cc


# --- changed lines -----------------------------------------------------------

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def changed_lines(root, base, head):
    """{path: set of head line numbers} that base..head adds or edits. A pure
    deletion marks the lines around it, so the enclosing function counts."""
    out = {}
    path = None
    for line in git(root, "diff", "-U0", "--no-renames", "--no-color", base, head).splitlines():
        if line.startswith("+++ "):
            name = line[4:].rstrip("\t")
            path = None if name == "/dev/null" else name[2:] if name.startswith("b/") else name
            if path is not None:
                out.setdefault(path, set())
            continue
        match = HUNK.match(line)
        if match and path is not None:
            start, count = int(match.group(1)), int(match.group(2) or 1)
            out[path].update(range(start, start + count) if count else (start, start + 1))
    return out


def show(root, rev, path):
    result = subprocess.run(["git", "show", rev + ":" + path], cwd=root, capture_output=True)
    return result.stdout.decode("utf-8", "replace") if result.returncode == 0 else None


# --- complexity ----------------------------------------------------------------

def python_complexity(node):
    """McCabe complexity of one function body, nested functions and classes
    excluded (they are scored on their own). 1 + one per decision point."""
    score = 1
    stack = list(ast.iter_child_nodes(node))
    while stack:
        item = stack.pop()
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        if isinstance(item, (ast.If, ast.IfExp, ast.For, ast.AsyncFor, ast.While, ast.ExceptHandler)):
            score += 1
        elif isinstance(item, ast.BoolOp):
            score += len(item.values) - 1
        elif isinstance(item, ast.comprehension):
            score += 1 + len(item.ifs)
        elif hasattr(ast, "match_case") and isinstance(item, ast.match_case):
            score += 1
        stack.extend(ast.iter_child_nodes(item))
    return score


def python_functions(source):
    """[{name, start, end, complexity, lines}] for every function, with the
    lines it owns: its body minus the bodies of nested functions and classes,
    and minus the def line, which runs at import whether or not it is called."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return None
    result = []

    def visit(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                name = prefix + child.name
                body_start = child.body[0].lineno if child.body else child.lineno
                if body_start == child.lineno:  # one-line def: keep the line
                    body_start = child.lineno
                owned = set(range(body_start, child.end_lineno + 1))
                for inner in ast.walk(child):
                    if inner is not child and isinstance(inner, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                        owned -= set(range(inner.lineno, inner.end_lineno + 1))
                result.append({"name": name, "start": child.lineno, "end": child.end_lineno,
                               "complexity": python_complexity(child), "lines": owned})
                visit(child, name + ".")
            elif isinstance(child, ast.ClassDef):
                visit(child, prefix + child.name + ".")
            else:
                visit(child, prefix)

    visit(tree, "")
    return result


def relative(root, path, sources=()):
    """A report path as a path from the repo root, or None outside the repo."""
    path = path.strip()
    candidates = [Path(path)] if os.path.isabs(path) else [Path(s) / path for s in sources] + [root / path]
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
            rel = resolved.relative_to(root)
        except (ValueError, OSError):
            continue
        if candidate is candidates[-1] or resolved.exists():
            return rel.as_posix()
    return None


def lizard_functions(root, csv_path):
    """{path: [function]} from `lizard --csv` (NLOC,CCN,token,PARAM,length,
    location,file,function,long_name,start,end)."""
    out = {}
    with open(csv_path, newline="") as stream:
        for row in csv.reader(stream):
            if len(row) < 11 or not row[1].strip().isdigit():
                continue  # a header or a malformed row
            path = relative(root, row[6])
            if path is None:
                continue
            start, end = int(row[9]), int(row[10])
            out.setdefault(path, []).append({"name": row[7], "start": start, "end": end,
                                             "complexity": int(row[1]), "lines": set(range(start, end + 1))})
    return out


# --- coverage ------------------------------------------------------------------

def read_coverage(root, files):
    """{path: {line: hits}} merged over LCOV and Cobertura reports."""
    lines = {}

    def add(path, number, hits):
        if path is None:
            return
        row = lines.setdefault(path, {})
        row[number] = max(row.get(number, 0), hits)

    for name in files:
        text = Path(name).read_text(errors="replace")
        if text.lstrip().startswith("<"):
            tree = ET.fromstring(text)
            sources = [s.text.strip() for s in tree.iter("source") if s.text and s.text.strip()]
            for cls in tree.iter("class"):
                path = relative(root, cls.get("filename", ""), sources)
                for line in cls.iter("line"):
                    add(path, int(line.get("number")), int(float(line.get("hits", "0"))))
        else:
            path = None
            for raw in text.splitlines():
                if raw.startswith("SF:"):
                    path = relative(root, raw[3:])
                    if path is not None:
                        lines.setdefault(path, {})
                elif raw.startswith("DA:") and path is not None:
                    parts = raw[3:].split(",")
                    add(path, int(parts[0]), int(float(parts[1])))
                elif raw == "end_of_record":
                    path = None
    return lines


# --- report --------------------------------------------------------------------

def report(args):
    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip()).resolve()
    base = git(root, "rev-parse", "--verify", args.base + "^{commit}").strip()
    head = git(root, "rev-parse", "--verify", args.head + "^{commit}").strip()
    coverage = read_coverage(root, args.coverage)
    external = lizard_functions(root, args.complexity) if args.complexity else {}
    if args.all:
        paths = [p for p in git(root, "ls-tree", "-r", "--name-only", head).splitlines()]
        touched = {p: None for p in paths if Path(p).suffix in CODE}
    else:
        touched = {p: lines for p, lines in changed_lines(root, base, head).items() if Path(p).suffix in CODE}
    rows, unmeasured = [], []
    for path in sorted(touched):
        source = show(root, head, path)
        if source is None:
            continue
        if path.endswith(".py"):
            functions = python_functions(source)
            old = show(root, base, path) if not args.all else None
            before = {f["name"]: f for f in (python_functions(old) or [])} if old else {}
        else:
            functions = external.get(path)
            before = None
        if functions is None:
            unmeasured.append(path)
            continue
        report_lines = coverage.get(path)
        for function in functions:
            if touched[path] is not None and not (touched[path] & set(range(function["start"], function["end"] + 1))):
                continue
            if report_lines is None:
                cov, data = 0.0, "none"
            else:
                instrumented = [n for n in function["lines"] if n in report_lines]
                cov = (sum(1 for n in instrumented if report_lines[n] > 0) / len(instrumented)) if instrumented else 0.0
                data = "measured" if instrumented else "none"
            score = crap(function["complexity"], cov)
            if args.all:
                change = "-"
            elif before is None:
                change = "changed"
            elif function["name"] in before:
                change = "modified"
            else:
                change = "added"
            rows.append({"file": path, "function": function["name"], "start": function["start"],
                         "end": function["end"], "complexity": function["complexity"],
                         "complexityBefore": (before[function["name"]]["complexity"]
                                              if before and function["name"] in before else None),
                         "coverage": round(cov, 4), "coverageData": data, "crap": round(score, 1),
                         "over": score >= args.threshold, "change": change})
    rows.sort(key=lambda r: (-r["crap"], r["file"], r["start"]))
    return {"tool": "crap", "version": 1, "formula": "CC^2 * (1 - coverage)^3 + CC",
            "base": base, "head": head, "threshold": args.threshold, "scope": "all" if args.all else "changed",
            "coverageFiles": [{"path": str(Path(f).resolve()), "sha256": hashlib.sha256(Path(f).read_bytes()).hexdigest()}
                              for f in args.coverage],
            "complexitySource": "python-ast" + (" + lizard" if args.complexity else ""),
            "functions": rows, "unmeasured": unmeasured,
            "summary": {"functions": len(rows), "over": sum(r["over"] for r in rows),
                        "noCoverageData": sum(r["coverageData"] == "none" for r in rows),
                        "unmeasuredFiles": len(unmeasured)}}


def markdown(data, limit=20):
    what = "all functions" if data["scope"] == "all" else "the changed functions"
    lines = ["CRAP of " + what + " (CC^2 x (1 - coverage)^3 + CC; threshold "
             + str(data["threshold"]) + "; base " + data["base"][:12] + ", head " + data["head"][:12] + ").", ""]
    rows = data["functions"]
    if not rows:
        lines.append("No changed function was measured.")
    else:
        lines += ["| CRAP | CC | Coverage | Function | Where | Change |", "|---|---|---|---|---|---|"]
        for r in rows[:limit]:
            flag = " **over**" if r["over"] else ""
            cov = ("%d%%" % round(r["coverage"] * 100)) if r["coverageData"] == "measured" else "no data"
            lines.append("| %s%s | %d | %s | `%s` | `%s:%d` | %s |" % (r["crap"], flag, r["complexity"], cov,
                                                                    r["function"], r["file"], r["start"], r["change"]))
        if len(rows) > limit:
            lines.append("")
            lines.append("%d more functions under the listed scores." % (len(rows) - limit))
    if data["unmeasured"]:
        lines += ["", "Unmeasured (no complexity data): " + ", ".join("`" + p + "`" for p in data["unmeasured"])]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--coverage", action="append", default=[], required=True)
    parser.add_argument("--complexity")
    parser.add_argument("--threshold", type=float, default=30.0)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--format", choices=["json", "markdown"], default="json")
    parser.add_argument("--fail-over", action="store_true")
    args = parser.parse_args()
    for name in args.coverage + ([args.complexity] if args.complexity else []):
        if not Path(name).is_file():
            raise SystemExit("crap: no such file: " + name)
    data = report(args)
    sys.stdout.write(json.dumps(data, indent=2) + "\n" if args.format == "json" else markdown(data))
    sys.exit(2 if args.fail_over and data["summary"]["over"] else 0)


if __name__ == "__main__":
    main()
