#!/usr/bin/env python3
"""Exercise real Git revisions, evidence capture and a stubbed Codex process."""
import fcntl
import json
import os
import signal
import time
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

    def traced_contract(self):
        self.contract["requirements"] = [
            {"id": "R-" + c["id"], "requirement": c["requirement"], "source": "PO #42 " + c["id"], "criteria": [c["id"]]}
            for c in self.contract["criteria"]]
        self.contract["documentation"] = {"reason": "operator instructions change", "items": [
            {"id": "DOC-1", "source": "docs/operations.md", "action": "update",
             "reason": "document approved behavior", "criteria": ["AC104"]}]}
        self.write(self.source, self.contract)
        self.bind("orchestrator")
        self.call("freeze", "story", str(self.source), "--require-traceability")
        self.bind("implement")

    def integrated(self, action="run", error=None, **env):
        return self.call(action, "story", "integrated", "all", self.base, error=error, **env)

    def all_checks(self):
        self.bind("implement")
        return self.check(criteria=",".join(c["id"] for c in self.contract["criteria"]), scope="integrated")

    def test_new_story_cannot_freeze_without_traceability(self):
        self.bind("orchestrator")
        self.call("freeze", "story", str(self.source), "--require-traceability", error="require requirements and documentation")

    def test_frozen_requirement_and_documentation_references_are_validated(self):
        self.traced_contract()
        from copy import deepcopy
        original = deepcopy(self.contract)
        mutations = [
            (lambda c: c.update(requirements=[]), "nonempty array"),
            (lambda c: c["requirements"].append(c["requirements"][0]), "duplicate requirement"),
            (lambda c: c["requirements"][0].update(source=""), "text and source"),
            (lambda c: c["requirements"][0].update(criteria=["unknown"]), "known criterion links"),
            (lambda c: c["requirements"].pop(), "every criterion must trace"),
            (lambda c: c["documentation"].update(reason=""), "assessment reason"),
            (lambda c: c["documentation"]["items"][0].update(criteria=[]), "docs need evidence criteria"),
            (lambda c: c["documentation"]["items"][0].update(criteria=["missing"]), "known criterion links"),
            (lambda c: c["documentation"]["items"][0].update(action="none"), "none must have no links"),
        ]
        self.bind("orchestrator")
        for mutate, error in mutations:
            with self.subTest(error=error):
                changed = deepcopy(original)
                mutate(changed)
                self.write(self.source, changed)
                self.call("freeze", "story", str(self.source), "--require-traceability", error=error)

    def test_no_documentation_impact_needs_a_recorded_assessment(self):
        self.traced_contract()
        self.contract["documentation"] = {"reason": "checked user/API/operations docs; internal-only refactor", "items": []}
        self.write(self.source, self.contract)
        self.bind("orchestrator")
        self.call("freeze", "story", str(self.source), "--require-traceability")

    def test_trace_derives_coverage_without_another_model_call(self):
        self.traced_contract()
        evidence = self.all_checks()
        reviewed = self.integrated()
        command_record = (self.root / "args.json").stat().st_mtime_ns
        trace = self.integrated("trace", FAKE_MODE="fail")
        self.assertEqual(trace["status"], "TRACE OK")
        self.assertEqual(len(trace["requirements"]), 5)
        self.assertTrue(all(r["status"] == "met" for r in trace["requirements"]))
        self.assertEqual(trace["documentation"][0]["tasks"], ["104"])
        self.assertEqual(trace["documentation"][0]["checks"], [evidence["evidence"]])
        self.assertEqual(trace["reviewHash"], reviewed["resultHash"])
        self.assertEqual(trace["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual((self.root / "args.json").stat().st_mtime_ns, command_record)
        prompt = json.loads((Path(reviewed["result"]).parent / "prompt.txt").read_text().split("\n", 1)[1])
        self.assertEqual(len(prompt["requirements"]), 5)
        self.assertEqual(prompt["documentation"]["items"][0]["id"], "DOC-1")

    def test_trace_cannot_certify_without_current_review_and_checks(self):
        self.traced_contract()
        self.integrated("trace", error="missing passing evidence")
        self.all_checks()
        self.integrated("trace", error="missing or stale review")
        self.integrated()
        (self.repo / "src/a.txt").write_text("changed after review")
        self.commit("new source")
        self.integrated("trace", error="missing passing evidence")

    def test_documentation_metadata_change_invalidates_frozen_approval(self):
        self.traced_contract()
        self.all_checks()
        self.integrated()
        self.contract["documentation"]["items"][0]["reason"] = "a newly changed scope"
        self.write(self.source, self.contract)
        self.integrated("trace", error="approve and freeze")

    def test_track_finder_receives_only_scoped_quality_obligations(self):
        self.traced_contract()
        self.bind("implement", "A")
        self.check()
        reviewed = self.review()
        prompt = json.loads((Path(reviewed["result"]).parent / "prompt.txt").read_text().split("\n", 1)[1])
        self.assertEqual([r["id"] for r in prompt["requirements"]], ["R-AC102"])
        self.assertEqual(prompt["documentation"]["items"], [])

    def test_trace_does_not_hide_acceptance_gaps(self):
        self.traced_contract()
        self.all_checks()
        self.integrated(FAKE_MODE="gap")
        self.integrated("trace", error="acceptance gap")

    def test_trace_does_not_hide_blocking_findings(self):
        self.traced_contract()
        self.all_checks()
        report = self.integrated(FAKE_MODE="finding")
        self.integrated("trace", error="blocking review findings")
        decisions = self.root / "decisions.json"
        self.write(decisions, {"reviewHash": report["resultHash"], "dismissed": [{"id": "F1", "reason": "reproduced false positive", "evidence": "source invariant and executed scenario"}]})
        self.assertEqual(self.call("trace", "story", "integrated", "all", self.base, str(decisions))["status"], "TRACE OK")

    def test_trace_labels_legacy_contracts_without_claiming_coverage(self):
        self.all_checks()
        self.integrated()
        result = self.integrated("trace")
        self.assertEqual(result["status"], "TRACE LEGACY")
        self.assertEqual(result["requirements"], [])

    def test_partial_track_cannot_claim_whole_story_traceability(self):
        self.check()
        self.review()
        self.review("trace", error="whole-story")

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
        # A failed call is not a round; it is bounded separately.
        self.assertEqual(recovered["round"], 1)
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

    def test_failed_calls_are_bounded_without_using_rounds(self):
        self.check()
        self.review(FAKE_MODE="fail", error="Codex review failed")
        self.review(FAKE_MODE="fail", error="Codex review failed")
        self.review(error="failed reviewer calls")

    def test_reset_reopens_a_scope_after_the_round_limit(self):
        self.all_checks()
        self.integrated(FAKE_MODE="finding")
        for number in (1, 2):
            (self.repo / "src/a.txt").write_text("fix " + str(number) + "\n")
            self.commit("fix")
            self.all_checks()
            self.integrated(FAKE_MODE="finding", error=None if number == 1 else "REVIEW LIMIT")
        self.integrated(error="REVIEW LIMIT")
        self.call("reset", "story", "integrated", "converging fixes", error="only the orchestrator")
        self.bind("orchestrator")
        self.call("reset", "story", "integrated", " ", error="only the orchestrator")
        reset = self.call("reset", "story", "integrated", "second docket fix; findings converge")
        self.assertEqual(reset["status"], "REVIEW RESET")
        self.bind("implement")
        self.assertEqual(self.integrated()["round"], 1)
        self.assertEqual(self.integrated("gate")["status"], "REVIEW OK")
        history = json.loads((self.plans / ".sessions/review-story/integrated.json").read_text())
        self.assertEqual(history["resets"][0]["reason"], "second docket fix; findings converge")

    def test_freeze_refuses_a_handoff_criterion_across_groups(self):
        self.bind("orchestrator")
        self.contract["criteria"].append({"id": "X", "tasks": ["102", "103"], "stage": "handoff",
                                          "requirement": "spans", "verification": "v"})
        self.write(self.source, self.contract)
        self.call("freeze", "story", str(self.source), error="spans tasks of different safe groups")
        self.contract["criteria"][-1]["stage"] = "integration"
        self.write(self.source, self.contract)
        self.call("freeze", "story", str(self.source))

    def test_freeze_refuses_checks_only_outside_a_track(self):
        self.bind("orchestrator")
        for task in ("101", "104"):
            self.contract["checksOnly"] = {task: "trivial"}
            self.write(self.source, self.contract)
            self.call("freeze", "story", str(self.source), error="checksOnly applies only to tasks of a track")

    def test_check_command_secrets_are_redacted(self):
        secret = "sk-live-0123456789abcdef"
        code = "import sys; print('ok')"
        record = self.call("check", "story", "track-A", "AC102", "--", sys.executable, "-c", code,
                           "Authorization: Bearer " + secret, "https://u:" + "p4ssw0rd" + "@host/x", "token=" + "abcdef123456",
                           API_TOKEN=secret)
        stored = json.dumps(record["command"])
        for leaked in (secret, "p4ssw0rd", "abcdef123456"):
            self.assertNotIn(leaked, stored)
        self.assertIn("$API_TOKEN", stored)
        report = self.review(API_TOKEN=secret)
        prompt = (Path(report["result"]).parent / "prompt.txt").read_text()
        self.assertNotIn(secret, prompt)

    def wait_for(self, predicate, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.05)
        self.fail("condition not reached")

    def running_attempt(self):
        receipt = self.plans / ".sessions/review-story/track-A.json"
        try:
            attempts = json.loads(receipt.read_text())["attempts"]
        except (OSError, ValueError):
            return None
        return attempts[-1] if attempts and attempts[-1].get("pgid") else None

    def alive(self, pgid):
        try:
            os.killpg(pgid, 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def test_terminated_recorder_stops_the_reviewer(self):
        self.check()
        recorder = subprocess.Popen([str(RUNNER), "run", "story", "track-A", "102", self.base], cwd=self.repo,
                                    env={**self.env, "FAKE_MODE": "timeout"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pgid = self.wait_for(self.running_attempt)["pgid"]
        self.assertTrue(self.alive(pgid))
        recorder.send_signal(signal.SIGTERM)
        _, stderr = recorder.communicate(timeout=10)
        self.assertIn(b"interrupted", stderr)
        self.wait_for(lambda: not self.alive(pgid))
        self.assertEqual(self.running_attempt()["exitCode"], "interrupted")
        self.assertEqual(self.review()["round"], 1)

    def test_killed_recorder_orphan_is_stopped_before_a_retry(self):
        self.check()
        recorder = subprocess.Popen([str(RUNNER), "run", "story", "track-A", "102", self.base], cwd=self.repo,
                                    env={**self.env, "FAKE_MODE": "timeout"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
        pgid = self.wait_for(self.running_attempt)["pgid"]
        os.killpg(recorder.pid, signal.SIGKILL)
        recorder.communicate(timeout=10)
        self.assertTrue(self.alive(pgid))
        self.assertEqual(self.review()["round"], 1)
        self.assertFalse(self.alive(pgid))

    def test_orphan_cleanup_spares_a_reused_pid(self):
        self.check()
        frozen = json.loads((self.plans / ".sessions/review-story/contract.json").read_text())
        other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "codex", "-o", "/elsewhere/result.json"],
                                 start_new_session=True)
        self.addCleanup(other.kill)
        receipt = self.plans / ".sessions/review-story/track-A.json"
        self.write(receipt, {"attempts": [{"contractHash": frozen["hash"], "inputs": "stale", "pgid": other.pid,
                                           "result": str(self.plans / "story.d/reviews/track-A/review-gone/result.json")}]})
        self.assertEqual(self.review()["round"], 1)
        self.assertTrue(self.alive(other.pid))


if __name__ == "__main__":
    unittest.main()
