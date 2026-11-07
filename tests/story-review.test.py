#!/usr/bin/env python3
"""Exercise real Git revisions, evidence capture and a stubbed Codex process."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "hooks/story-review.sh"

FAKE_CODEX = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
pathlib.Path(os.environ['FAKE_ARGS']).write_text(json.dumps(args))
prompt = sys.stdin.read()
data = json.loads(prompt.split('\\n', 1)[1])
mode = os.environ.get('FAKE_MODE', 'pass')
if mode == 'timeout': time.sleep(30)
if mode == 'fail': sys.exit(7)
if mode == 'missing': sys.exit(0)
criteria = [{'id': c['id'], 'assessment': 'gap' if mode == 'gap' else 'met', 'evidence': 'source and captured test output'} for c in data['criteria']]
if mode == 'wrong': criteria = []
findings = [{'id':'F1','severity':'blocking','file':'src/a.txt','detail':'observable failure','evidence':'reproducer at reviewed head'}] if mode == 'finding' else []
out = pathlib.Path(args[args.index('-o')+1])
out.write_text(json.dumps({'criteria':criteria,'findings':findings}))
if mode == 'dirty': pathlib.Path('unexpected.txt').write_text('changed')
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':12,'output_tokens':4}}))
'''


class ReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="story review ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / ".gitignore").write_text(".plans/\n")
        (self.repo / "src").mkdir()
        (self.repo / "src/a.txt").write_text("before\n")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD")
        (self.repo / "src/a.txt").write_text("after\n")
        self.commit("feature")
        self.plans = self.repo / ".plans"
        (self.plans / ".sessions").mkdir(parents=True)
        (self.plans / "story.md").write_text("""## Order of work
| Task | Wave | Depends | Files | Track |
|---|---|---|---|---|
| 101 | F | - | src/contract.txt | - |
| 102 | T | 101 | src/a.txt | A |
| 103 | T | 101 | src/b.txt | B |
| 104 | I | 102,103 | docs/ | - |
""")
        self.config = self.root / "config.json"
        self.write(self.config, {"parallel": {"max": 10}})
        self.source = self.plans / "acceptance.json"
        self.contract = {"tasks": ["101", "102", "103", "104"], "criteria": [
            {"id": "AC" + task, "tasks": [task], "stage": "handoff", "requirement": "task works", "verification": "run targeted check"}
            for task in ("101", "102", "103", "104")
        ] + [{"id": "STORY", "tasks": ["101", "102", "103", "104"], "stage": "integration",
              "requirement": "runtime wiring works", "verification": "run integrated scenario"}]}
        self.write(self.source, self.contract)
        binary = self.root / "bin"
        binary.mkdir()
        (binary / "codex").write_text(FAKE_CODEX)
        (binary / "codex").chmod(0o755)
        self.env = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                    "CLAUDE_CODE_HOST_SESSION_ID": "fixture", "CLAUDE_PROJECT_DIR": str(self.repo),
                    "STORY_CONFIG": str(self.config), "STORY_PLANS_DIR": str(self.plans),
                    "FAKE_ARGS": str(self.root / "args.json"), "FAKE_MODE": "pass"}
        self.bind("orchestrator")
        self.call("freeze", "story", str(self.source))
        self.bind("implement", "A")

    def write(self, path, data):
        Path(path).write_text(json.dumps(data))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo).decode().strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def bind(self, role, track=None):
        self.write(self.plans / ".sessions/fixture.json", {"role": role, "slug": "story", "track": track})

    def call(self, *args, error=None, **env):
        result = subprocess.run([str(RUNNER), *args], cwd=self.repo, env={**self.env, **env}, capture_output=True, text=True)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(error, result.stderr)
        return result

    def check(self, criteria="AC102", scope="track-A", code="print('verified')", error=None):
        return self.call("check", "story", scope, criteria, "--", sys.executable, "-c", code, error=error)

    def review(self, action="run", error=None, **env):
        return self.call(action, "story", "track-A", "102", self.base, error=error, **env)

    def test_pass_and_explicit_cli_settings(self):
        self.assertEqual(self.check()["cwd"], str(self.repo.resolve()))
        report = self.review()
        self.assertEqual(report["status"], "REVIEW READY")
        self.assertEqual(self.review("gate")["status"], "REVIEW OK")
        command = json.loads((self.root / "args.json").read_text())
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertIn("--ephemeral", command)
        self.assertIn('model_reasoning_effort="high"', command)

    def test_freeze_requires_orchestrator(self):
        self.call("freeze", "story", str(self.source), error="only the orchestrator")

    def test_contract_must_cover_claims(self):
        self.bind("orchestrator")
        self.contract["tasks"].append("999")
        self.contract["criteria"].append({"id": "AC999", "tasks": ["999"], "stage": "handoff", "requirement": "extra", "verification": "check"})
        self.write(self.source, self.contract)
        self.call("freeze", "story", str(self.source), error="exactly the claim tasks")

    def test_contract_requires_whole_story_criterion(self):
        self.bind("orchestrator")
        self.contract["criteria"] = self.contract["criteria"][:-1]
        self.write(self.source, self.contract)
        self.call("freeze", "story", str(self.source), error="integration criterion")

    def test_contract_edits_invalidate_evidence(self):
        self.contract["criteria"][0]["requirement"] = "weaker"
        self.write(self.source, self.contract)
        self.check(error="approve and freeze")

    def test_missing_evidence_blocks_review(self):
        self.review(error="missing passing evidence")

    def test_changed_source_invalidates_checks(self):
        self.check()
        (self.repo / "src/a.txt").write_text("another version")
        self.commit("fix")
        self.review(error="missing passing evidence")

    def test_changed_source_invalidates_review(self):
        self.check()
        self.review()
        (self.repo / "src/a.txt").write_text("new source")
        self.commit("new source")
        self.check()
        self.review("gate", error="missing or stale review")

    def test_model_or_effort_change_requires_new_review(self):
        self.check()
        self.review()
        self.write(self.config, {"handoffReview": {"model": "fixture-model", "effort": "medium"}})
        self.review("gate", error="missing or stale review")
        self.assertEqual(self.review()["round"], 2)
        command = json.loads((self.root / "args.json").read_text())
        self.assertEqual(command[command.index("--model") + 1], "fixture-model")

    def test_dirty_source_cannot_be_certified(self):
        (self.repo / "src/a.txt").write_text("dirty")
        self.check(error="working tree must be clean")

    def test_failed_check_is_not_success(self):
        self.check(code="raise SystemExit(2)", error="check failed")
        self.review(error="a current check failed")

    def test_recovered_check_can_supersede_failure(self):
        self.check(code="raise SystemExit(2)", error="check failed")
        self.check()
        self.review()

    def test_check_cannot_mutate_reviewed_source(self):
        self.check(code="from pathlib import Path; Path('src/a.txt').write_text('oops')", error="changed the reviewed source")

    def test_check_log_tampering_is_detected(self):
        record = self.check()
        Path(record["log"]).write_text("fabricated output")
        self.review(error="output was changed")

    def test_repeat_failed_command_is_bounded(self):
        for _ in range(2):
            self.check(code="raise SystemExit(2)", error="check failed")
        self.check(code="raise SystemExit(2)", error="CHECK LIMIT")

    def test_review_cannot_omit_or_borrow_tasks(self):
        self.check()
        self.call("run", "story", "track-A", "103", self.base, error="exactly the assigned safe group")
        self.call("run", "story", "track-B", "103", self.base, error="only its own review scope")

    def test_blocking_finding_requires_validation(self):
        self.check()
        report = self.review(FAKE_MODE="finding")
        self.review("gate", error="blocking review findings")
        decisions = self.root / "decisions.json"
        self.write(decisions, {"reviewHash": report["resultHash"], "dismissed": [{"id": "F1", "reason": "false positive", "evidence": "reproducer passes and invariant is enforced at source line 10"}]})
        self.call("gate", "story", "track-A", "102", self.base, str(decisions))

    def test_dismissals_cannot_be_replayed_from_another_review(self):
        self.check()
        self.review(FAKE_MODE="finding")
        decisions = self.root / "decisions.json"
        self.write(decisions, {"reviewHash": "stale", "dismissed": []})
        self.call("gate", "story", "track-A", "102", self.base, str(decisions), error="this exact review hash")

    def test_acceptance_gap_is_not_overridden_by_clean_tests(self):
        self.check()
        self.review(FAKE_MODE="gap")
        self.review("gate", error="acceptance gap")

    def test_identical_review_is_reused_without_new_call(self):
        self.check()
        first = self.review()
        second = self.review(FAKE_MODE="fail")
        self.assertEqual(first["resultHash"], second["resultHash"])
        self.assertEqual(second["round"], 1)

    def test_review_fix_loop_is_bounded(self):
        for number in range(2):
            self.check()
            self.review()
            (self.repo / "src/a.txt").write_text("revision " + str(number))
            self.commit("fix")
        self.check()
        self.review(error="REVIEW LIMIT")

    def test_failed_cli_is_never_a_clean_review(self):
        self.check()
        self.review(FAKE_MODE="fail", error="Codex review failed")
        self.review("gate", error="missing or stale review")
        recovered = self.review()
        self.assertEqual(recovered["round"], 2)
        prompt = (Path(recovered["result"]).parent / "prompt.txt").read_text()
        self.assertEqual(json.loads(prompt.split("\n", 1)[1])["focusDiffBase"], self.base)

    def test_missing_and_malformed_results_are_rejected(self):
        self.check()
        self.review(FAKE_MODE="missing", error="Codex review failed")
        self.review(FAKE_MODE="wrong", error="every scoped criterion")
        self.review("gate", error="missing or stale review")

    def test_reviewer_source_mutation_is_detected(self):
        self.check()
        self.review(FAKE_MODE="dirty", error="working tree must be clean")

    def test_review_result_tampering_is_detected(self):
        self.check()
        report = self.review()
        Path(report["result"]).write_text("{}")
        self.review("gate", error="result changed")

    def test_busy_review_slot_queues_without_consuming_attempt(self):
        self.write(self.config, {"parallel": {"max": 10}, "handoffReview": {"maxParallel": 1}})
        self.check()
        state = self.plans / ".sessions/review-story"
        with (state / "slot-0.lock").open("a+") as busy:
            fcntl.flock(busy, fcntl.LOCK_EX)
            self.assertEqual(self.review(error="REVIEW QUEUED").returncode, 3)
        self.assertEqual(self.review()["round"], 1)

    def test_timeout_is_not_a_pass(self):
        self.write(self.config, {"parallel": {"max": 10}, "handoffReview": {"timeoutSeconds": 1}})
        self.check()
        self.review(FAKE_MODE="timeout", error="timed out")
        self.review("gate", error="missing or stale review")

    def test_explicit_checks_only_for_trivial_track(self):
        self.bind("orchestrator")
        self.contract["checksOnly"] = {"102": "approved copy-only change"}
        self.write(self.source, self.contract)
        self.call("freeze", "story", str(self.source))
        self.bind("implement", "A")
        self.check()
        self.assertEqual(self.review("gate")["status"], "CHECKS ONLY")
        self.assertFalse((self.root / "args.json").exists())

    def test_integrated_review_requires_story_evidence(self):
        self.bind("implement")
        self.check(criteria="AC101,AC102,AC103,AC104", scope="integrated")
        self.call("run", "story", "integrated", "all", self.base, error="missing passing evidence")
        self.check(criteria="STORY", scope="integrated")
        self.call("run", "story", "integrated", "all", self.base)
        self.call("gate", "story", "integrated", "all", self.base)


if __name__ == "__main__":
    unittest.main()
