#!/usr/bin/env python3
"""crap.py: the formula, complexity, coverage parsing and changed-function scope,
against hand-computed values in real Git repositories."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = [ROOT / "hooks/crap.py", ROOT / "plugins/review-panel/skills/review-panel/scripts/crap.py"]
spec = importlib.util.spec_from_file_location("crap", SCRIPTS[0])
crap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crap)

SAMPLE = textwrap.dedent('''\
    def a():
        return 1

    def b(x):
        if x and x > 1:
            return 1
        elif x:
            return 2
        return 3

    def c(xs):
        for x in xs:
            pass
        ys = [y for y in xs if y]
        try:
            pass
        except ValueError:
            pass
        except KeyError:
            pass
        while False:
            pass
        return 1 if ys else 0

    def outer():
        def inner(z):
            if z:
                return z
        if True:
            return inner

    class K:
        def m(self, v):
            return v or 0
    ''')


class Formula(unittest.TestCase):
    def test_reference_values(self):
        self.assertEqual(crap.crap(1, 0), 2)
        self.assertEqual(crap.crap(5, 0), 30)       # the classic threshold
        self.assertEqual(crap.crap(10, 1), 10)      # full coverage leaves CC
        self.assertEqual(crap.crap(10, 0.5), 22.5)  # 100 * 0.125 + 10
        self.assertGreaterEqual(crap.crap(30, 1), 30)  # CC 30 is over at any coverage

    def test_python_complexity_matches_hand_count(self):
        got = {f["name"]: f["complexity"] for f in crap.python_functions(SAMPLE)}
        self.assertEqual(got, {"a": 1, "b": 4, "c": 8, "outer": 2, "outer.inner": 2, "K.m": 2})

    def test_owned_lines_exclude_def_line_and_nested_functions(self):
        rows = {f["name"]: f for f in crap.python_functions(SAMPLE)}
        outer = rows["outer"]
        self.assertNotIn(outer["start"], outer["lines"])
        self.assertTrue(set(range(rows["outer.inner"]["start"], rows["outer.inner"]["end"] + 1)).isdisjoint(outer["lines"]))

    def test_both_plugins_ship_the_same_script(self):
        self.assertEqual(SCRIPTS[0].read_bytes(), SCRIPTS[1].read_bytes())


class Report(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="crap test ")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        (self.repo / "pkg dir").mkdir(parents=True)
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.mod = self.repo / "pkg dir/m.py"
        self.mod.write_text("def a():\n    return 1\n\ndef keep():\n    return 0\n")
        (self.repo / "web.ts").write_text("export const x = 1;\n")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD")
        self.mod.write_text("def a():\n    return 2\n\ndef keep():\n    return 0\n\n"
                            "def b(x):\n    if x and x > 1:\n        return 1\n    elif x:\n        return 2\n    return 3\n")
        (self.repo / "web.ts").write_text("export function f(a) {\n  if (a) { return 1; }\n  return 2;\n}\n")
        self.commit("head")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo).decode().strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def run_crap(self, *args, code=0):
        result = subprocess.run([sys.executable, str(SCRIPTS[0]), "--base", self.base, *args],
                                cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr)
        return result.stdout

    def lcov(self, name, covered, uncovered, path="pkg dir/m.py"):
        target = Path(self.tmp.name) / name
        rows = ["SF:" + str(self.repo / path)] + ["DA:%d,1" % n for n in covered] + ["DA:%d,0" % n for n in uncovered]
        target.write_text("\n".join(rows + ["end_of_record"]) + "\n")
        return str(target)

    def functions(self, out):
        return {r["function"]: r for r in json.loads(out)["functions"]}

    def test_scores_only_changed_functions(self):
        rows = self.functions(self.run_crap("--coverage", self.lcov("c.info", [2], [8, 9, 10, 11, 12])))
        self.assertEqual(set(rows), {"a", "b"})  # keep() is unchanged
        self.assertEqual((rows["a"]["change"], rows["a"]["coverage"], rows["a"]["crap"]), ("modified", 1.0, 1.0))
        self.assertEqual((rows["b"]["change"], rows["b"]["complexity"], rows["b"]["crap"]), ("added", 4, 20.0))

    def test_partial_coverage(self):
        rows = self.functions(self.run_crap("--coverage", self.lcov("c.info", [2, 8, 9], [10, 11, 12])))
        self.assertEqual(rows["b"]["coverage"], 0.4)  # 2 of 5 body lines
        self.assertEqual(rows["b"]["crap"], round(16 * 0.6 ** 3 + 4, 1))

    def test_threshold_and_fail_over(self):
        cov = self.lcov("c.info", [2], [8, 9, 10, 11, 12])
        self.run_crap("--coverage", cov, "--threshold", "10", "--fail-over", code=2)
        self.run_crap("--coverage", cov, "--threshold", "30", "--fail-over", code=0)

    def test_missing_coverage_is_not_a_pass(self):
        rows = self.functions(self.run_crap("--coverage", self.lcov("other.info", [1], [], path="web.ts")))
        self.assertEqual((rows["b"]["coverageData"], rows["b"]["coverage"]), ("none", 0.0))

    def test_other_languages_need_lizard_and_are_never_scored_silently(self):
        data = json.loads(self.run_crap("--coverage", self.lcov("c.info", [2], [])))
        self.assertEqual(data["unmeasured"], ["web.ts"])
        lizard = Path(self.tmp.name) / "lizard.csv"
        lizard.write_text("NLOC,CCN,token,PARAM,length,location,file,function,long_name,start,end\n"
                          '4,2,20,1,4,"f@1-4@./web.ts",./web.ts,f,f( a ),1,4\n')
        cov = self.lcov("ts.info", [2, 3], [], path="web.ts")
        rows = self.functions(self.run_crap("--coverage", cov, "--complexity", str(lizard)))
        self.assertEqual((rows["f"]["complexity"], rows["f"]["coverage"], rows["f"]["change"]), (2, 1.0, "changed"))

    def test_cobertura_with_relative_source(self):
        xml = Path(self.tmp.name) / "cobertura.xml"
        xml.write_text('<?xml version="1.0"?><coverage><sources><source>%s</source></sources><packages><package>'
                       '<classes><class filename="m.py"><lines><line number="8" hits="3"/><line number="9" hits="0"/>'
                       '</lines></class></classes></package></packages></coverage>' % (self.repo / "pkg dir"))
        rows = self.functions(self.run_crap("--coverage", str(xml)))
        self.assertEqual(rows["b"]["coverage"], 0.5)

    def test_merged_reports_take_any_hit(self):
        one = self.lcov("1.info", [8], [9, 10, 11, 12])
        two = self.lcov("2.info", [9, 10, 11, 12], [8])
        rows = self.functions(self.run_crap("--coverage", one, "--coverage", two))
        self.assertEqual(rows["b"]["coverage"], 1.0)

    def test_report_is_bound_to_revisions_and_inputs(self):
        cov = self.lcov("c.info", [2], [])
        data = json.loads(self.run_crap("--coverage", cov))
        self.assertEqual((data["base"], data["head"]), (self.base, self.git("rev-parse", "HEAD")))
        self.assertEqual(len(data["coverageFiles"][0]["sha256"]), 64)

    def test_markdown_flags_over_threshold(self):
        out = self.run_crap("--coverage", self.lcov("c.info", [2], [8, 9, 10, 11, 12]),
                            "--threshold", "10", "--format", "markdown")
        self.assertIn("| 20.0 **over** | 4 | 0% | `b` | `pkg dir/m.py:7` | added |", out)


if __name__ == "__main__":
    unittest.main()
