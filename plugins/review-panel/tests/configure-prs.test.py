#!/usr/bin/env python3
"""watch.py against a fake `az` and a local git repo standing in for Azure Repos."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WATCH = Path(__file__).resolve().parents[1] / "skills/configure-prs/scripts/watch.py"

FAKE_AZ = r'''#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_AZ_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]
with open(os.environ["FAKE_AZ_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if not state.get("login", True):
    sys.stderr.write("ERROR: Before you can run Azure DevOps commands, you need to run the login command(az login if using AAD/MSA identity else az devops login if using PAT token) to setup credentials.\n")
    sys.exit(1)
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def out(value):
    print(json.dumps(value)); sys.exit(0)
if args[:2] == ["account", "show"]:
    out(state["account"])
if args[:3] == ["repos", "pr", "list"]:
    prs = state["prs"].get(opt("--org") + "|" + opt("--project"), [])
    repo = opt("--repository")
    out([p for p in prs if repo is None or p["repository"]["name"] == repo])
if args[:3] == ["repos", "pr", "show"]:
    for prs in state["prs"].values():
        for p in prs:
            if str(p["pullRequestId"]) == opt("--id"):
                out(p)
    sys.stderr.write("not found\n"); sys.exit(1)
if args[:2] == ["devops", "invoke"]:
    route = dict(a.split("=", 1) for a in args[args.index("--route-parameters") + 1:] if "=" in a and not a.startswith("--"))
    key = route["repositoryId"] + "/" + route["pullRequestId"]
    threads = state["threads"].setdefault(key, [])
    if opt("--http-method") == "GET":
        out({"count": len(threads), "value": threads})
    payload = json.load(open(opt("--in-file")))
    payload["id"] = len(threads) + 1
    for c in payload["comments"]:
        c.setdefault("publishedDate", "2026-11-11T10:%02d:00Z" % payload["id"])
    threads.append(payload)
    json.dump(state, open(state_path, "w"))
    out(payload)
sys.stderr.write("fake az: unhandled " + " ".join(args) + "\n"); sys.exit(1)
'''


FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, re, subprocess, sys
prompt = sys.stdin.read()
record = {"argv": sys.argv[1:], "cwd": os.getcwd(),
          "host": os.environ.get("CLAUDE_CODE_HOST_SESSION_ID"), "effortEnv": os.environ.get("CLAUDE_CODE_EFFORT_LEVEL")}
open(os.environ["FAKE_CLAUDE_LOG"], "w").write(json.dumps(record))
print(json.dumps({"type": "system", "subtype": "init", "model": sys.argv[sys.argv.index("--model") + 1]}))
w, key, docket = re.search(r'python3 (\S+) post (\S+) "([^"]+)"`', prompt).groups()
head = re.search(r"Reviewed head: ([0-9a-f]{40})", prompt).group(1)
if os.environ.get("FAKE_CLAUDE_MODE", "post") == "post":
    open(docket, "w").write(json.dumps({"head": head, "summary": "Approved with comments.", "items": [
        {"polarity": "Should fix", "file": "src/a.txt", "line": 21, "body": "verified issue"}]}))
    subprocess.run([sys.executable, w, "post", key, docket], check=True, capture_output=True)
    last = "REVIEWED approved-with-comments 1"
else:
    last = "FAILED could not verify"
print(json.dumps({"type": "result", "subtype": "success", "total_cost_usd": 0.42, "result": "done\n" + last}))
"""

FAKE_PREPARE = """#!/usr/bin/env bash
set -eu
base="$1"; head="$2"; out=""; while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out/heads"; printf '## Verified facts\\n' > "$out/facts.md"
git diff "$base" "$head" > "$out/diff.patch" 2>/dev/null || true; printf '# Review scope\\n' > "$out/scope.md"; echo "$out"
"""

FAKE_HEADS = """#!/usr/bin/env bash
set -eu
scope="$1"; heads="$3"
printf '%s\\n' "$heads" > "$scope/heads/requested.txt"
printf 'head\\texit\\tbytes\\tstarted\\tfinished\\n' > "$scope/heads/status.tsv"
for h in ${heads//,/ }; do
  if [ "${FAKE_HEADS_MODE:-ok}" = ok ]; then echo "### F1" > "$scope/heads/$h.out.md"; printf '%s\\t0\\t6\\tx\\ty\\n' "$h" >> "$scope/heads/status.tsv"
  else printf '%s\\t1\\t0\\tx\\ty\\n' "$h" >> "$scope/heads/status.tsv"; fi
done
"""

ORG = "https://dev.azure.com/contoso"


def pr(number, head, repo="Webshop", draft=False, by="alex@contoso.com", by_id="id-alex", status="active"):
    return {"pullRequestId": number, "isDraft": draft, "status": status, "title": "PR %d" % number,
            "createdBy": {"uniqueName": by, "id": by_id, "displayName": by.split("@")[0]},
            "repository": {"id": "repo-" + repo, "name": repo, "remoteUrl": "unused"},
            "sourceRefName": "refs/heads/feature", "targetRefName": "refs/heads/main",
            "lastMergeSourceCommit": {"commitId": head}}


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="watch prs ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "az").write_text(FAKE_AZ)
        (bin_dir / "az").chmod(0o755)
        self.state_path = self.root / "az-state.json"
        self.log = self.root / "az.log"
        self.env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                    "FAKE_AZ_STATE": str(self.state_path), "FAKE_AZ_LOG": str(self.log),
                    "REVIEW_WATCH_HOME": str(self.root / "home")}
        (bin_dir / "claude").write_text(FAKE_CLAUDE)
        (bin_dir / "claude").chmod(0o755)
        panel = self.root / "panel"
        panel.mkdir()
        for name, body in (("prepare-scope.sh", FAKE_PREPARE), ("run-heads.sh", FAKE_HEADS)):
            (panel / name).write_text(body)
            (panel / name).chmod(0o755)
        self.env.update({"FAKE_CLAUDE_LOG": str(self.root / "claude.json"), "REVIEW_WATCH_PANEL_SCRIPTS": str(panel),
                         "CLAUDE_CODE_HOST_SESSION_ID": "local_parent", "CLAUDE_CODE_EFFORT_LEVEL": "max"})
        self.az_state = {"account": {"user": {"name": "Sam@Contoso.com"}}, "prs": {}, "threads": {}}
        self.save()

    def save(self):
        self.state_path.write_text(json.dumps(self.az_state))

    def load(self):
        self.az_state = json.loads(self.state_path.read_text())
        return self.az_state

    def run_watch(self, *args, code=0, **env):
        result = subprocess.run([sys.executable, str(WATCH), *args], env={**self.env, **env},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def setup_project(self, *urls):
        return json.loads(self.run_watch("setup", *(urls or (ORG + "/Webshop",))).stdout)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    # ------------------------------------------------------------------ setup

    def test_setup_parses_urls_and_reads_identity(self):
        cfg = self.setup_project(
            "https://contoso@dev.azure.com/contoso/Webshop/_git/Payments%20Api",
            "https://contoso.visualstudio.com/Webshop/_git/Webshop/pullrequest/4",
            "https://dev.azure.com/fabrikam/Team%20Alpha%20-%20Core")
        self.assertEqual(cfg["me"], ["sam@contoso.com"])
        self.assertEqual([(p["org"], p["project"], p["repos"]) for p in cfg["projects"]],
                         [("contoso", "Webshop", ["Payments Api", "Webshop"]),
                          ("fabrikam", "Team Alpha - Core", None)])
        self.assertEqual(cfg["hours"], [8, 18])
        self.assertEqual(cfg["intervalSeconds"], 1800)

    def test_a_project_url_watches_every_repo(self):
        cfg = self.setup_project(ORG + "/Webshop/_git/Webshop", ORG + "/Webshop")
        self.assertIsNone(cfg["projects"][0]["repos"])

    def test_setup_refuses_other_hosts_and_takes_an_explicit_identity(self):
        self.assertIn("not an Azure DevOps URL", self.run_watch("setup", "https://github.com/x/y", code=1).stderr)
        self.assertIn("not a project URL", self.run_watch("setup", "https://dev.azure.com/contoso", code=1).stderr)
        cfg = json.loads(self.run_watch("setup", ORG + "/Webshop", "--me", "id-sam", "--me", "Sam@Contoso.com").stdout)
        self.assertEqual(cfg["me"], ["id-sam", "sam@contoso.com"])

    def test_no_config_is_an_error(self):
        self.assertIn("no config", self.run_watch("show", code=1).stderr)

    # ------------------------------------------------------------- candidates

    def test_candidates_skip_drafts_own_and_reviewed_heads(self):
        self.setup_project()
        a, b = "a" * 40, "b" * 40
        self.az_state["prs"][ORG + "|Webshop"] = [
            pr(1, a), pr(2, a, draft=True), pr(3, a, by="SAM@contoso.com", by_id="x"),
            pr(4, a), pr(5, b)]
        self.az_state["threads"]["repo-Webshop/4"] = [
            {"comments": [{"content": "ok <sub>review-watch head " + a + "</sub>", "publishedDate": "2026-11-10"}]}]
        self.az_state["threads"]["repo-Webshop/5"] = [
            {"comments": [{"content": "review-watch head " + a, "publishedDate": "2026-11-10"}]}]
        self.save()
        found = json.loads(self.run_watch("candidates").stdout)
        self.assertEqual([(c["prId"], c["previousHead"]) for c in found], [(1, None), (5, a)])
        self.assertEqual(found[0]["key"], "contoso/Webshop/repo-Webshop/1")
        self.assertEqual(found[0]["url"], ORG + "/Webshop/_git/Webshop/pullrequest/1")

    def test_own_pr_is_matched_by_id_too(self):
        self.run_watch("setup", ORG + "/Webshop", "--me", "ID-SAM")
        self.az_state["prs"][ORG + "|Webshop"] = [pr(1, "a" * 40, by="other", by_id="id-sam")]
        self.save()
        self.assertEqual(json.loads(self.run_watch("candidates").stdout), [])

    def test_pipeline_and_skipped_authors_get_no_review(self):
        self.run_watch("setup", ORG + "/Webshop", "--skip", "Dependabot")
        build = pr(1, "a" * 40, by="Build\\4f97b8db", by_id="b")
        build["createdBy"]["descriptor"] = "svc.abc"
        service = pr(2, "a" * 40, by="x", by_id="s")
        service["createdBy"]["descriptor"] = "svc.def"
        named = pr(3, "a" * 40, by="dep@x", by_id="d")
        named["createdBy"]["displayName"] = "Dependabot"
        self.az_state["prs"][ORG + "|Webshop"] = [build, service, named, pr(4, "a" * 40)]
        self.save()
        self.assertEqual([c["prId"] for c in json.loads(self.run_watch("candidates").stdout)], [4])

    def test_a_head_that_failed_twice_is_skipped(self):
        self.setup_project()
        self.az_state["prs"][ORG + "|Webshop"] = [pr(1, "a" * 40)]
        self.save()
        key = "contoso/Webshop/repo-Webshop/1"
        self.run_watch("fail", key, "a" * 40, "codex timed out")
        self.assertEqual(len(json.loads(self.run_watch("candidates").stdout)), 1)
        self.run_watch("fail", key, "a" * 40, "codex timed out")
        self.assertEqual(json.loads(self.run_watch("candidates").stdout), [])

    # ------------------------------------------------------------------- poll

    def test_poll_reports_candidates_in_the_window(self):
        self.setup_project()
        self.az_state["prs"][ORG + "|Webshop"] = [pr(1, "a" * 40)]
        self.save()
        out = self.run_watch("poll", "--once", "--now", "2026-11-11T09:00:00").stdout
        self.assertTrue(out.startswith("CANDIDATES "))
        self.assertEqual(json.loads(out[len("CANDIDATES "):])[0]["prId"], 1)

    def test_poll_outside_the_window_makes_no_calls(self):
        self.setup_project()
        before = len(self.calls())
        for now in ("2026-11-14T10:00:00", "2026-11-11T07:59:00", "2026-11-11T18:00:00"):
            self.assertEqual(self.run_watch("poll", "--once", "--now", now).stdout.strip(), "NONE")
        self.assertEqual(len(self.calls()), before)

    def test_poll_stops_on_a_lost_login(self):
        self.setup_project()
        self.az_state["login"] = False
        self.save()
        self.assertIn("az login", self.run_watch("poll", "--once", "--now", "2026-11-11T09:00:00", code=2).stderr)

    def test_one_poller_per_machine(self):
        self.setup_project()
        import fcntl
        home = self.root / "home"
        with (home / "poll.lock").open("a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertIn("ALREADY WATCHING", self.run_watch("poll", "--once", code=4).stderr)
        self.run_watch("poll", "--once", "--now", "2026-11-14T10:00:00")

    # --------------------------------------------------------- checkout, post

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.remote, capture_output=True, text=True,
                              check=True).stdout.strip()

    def remote_repo(self):
        self.remote = self.root / "remote repo"
        self.remote.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "T")
        (self.remote / "src").mkdir()
        (self.remote / "src/a.txt").write_text("".join("line %d\n" % n for n in range(1, 21)))
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("switch", "-q", "-c", "feature")
        (self.remote / "src/a.txt").write_text("".join("line %d\n" % n for n in range(1, 31)))
        self.git("commit", "-qam", "first")
        self.first = self.git("rev-parse", "HEAD")
        (self.remote / "src/b.txt").write_text("new\n")
        self.git("add", ".")
        self.git("commit", "-qm", "second")
        self.head = self.git("rev-parse", "HEAD")
        self.git("switch", "-q", "main")
        self.setup_project()
        self.az_state["prs"][ORG + "|Webshop"] = [pr(7, self.head)]
        self.save()
        self.key = "contoso/Webshop/repo-Webshop/7"
        self.env["REVIEW_WATCH_CLONE_URL"] = str(self.remote)

    def checkout(self, *extra):
        return json.loads(self.run_watch("checkout", self.key, *extra).stdout)

    def docket(self, items, head=None):
        self.dockets = getattr(self, "dockets", 0) + 1
        path = self.root / ("docket-%d.json" % self.dockets)
        path.write_text(json.dumps({"head": head or self.head, "summary": "Approved with comments.", "items": items}))
        return str(path)

    def test_checkout_makes_a_worktree_at_the_pr_head(self):
        self.remote_repo()
        info = self.checkout()
        self.assertEqual(info["head"], self.head)
        self.assertEqual(info["rangeBase"], self.base)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=info["worktree"]), self.head)
        self.assertEqual(info["files"], 2)
        self.assertFalse(info["tooBig"])
        again = self.checkout("--previous", self.first)
        self.assertTrue(again["delta"])
        self.assertEqual(again["rangeBase"], self.first)
        self.assertFalse(self.checkout("--previous", "f" * 40)["delta"])

    def test_post_writes_inline_threads_and_a_marked_summary(self):
        self.remote_repo()
        self.checkout()
        items = [{"polarity": "Should fix", "file": "src/a.txt", "line": 25, "endLine": 27, "body": "Off by one."},
                 {"polarity": "Nit", "file": "src/b.txt", "line": 1, "body": "Name it."}]
        self.run_watch("post", self.key, self.docket(items))
        threads = self.load()["threads"]["repo-Webshop/7"]
        self.assertEqual(len(threads), 2)
        inline, summary = threads
        self.assertEqual(inline["threadContext"]["filePath"], "/src/a.txt")
        self.assertEqual(inline["threadContext"]["rightFileStart"]["line"], 25)
        self.assertEqual(inline["threadContext"]["rightFileEnd"]["line"], 27)
        self.assertIn("**Should fix**", inline["comments"][0]["content"])
        self.assertEqual(summary["status"], 4)
        self.assertNotIn("threadContext", summary)
        self.assertIn("Name it.", summary["comments"][0]["content"])
        self.assertIn("review-watch head " + self.head, summary["comments"][0]["content"])
        self.assertEqual(json.loads(self.run_watch("candidates").stdout), [])
        posts = [c for c in self.calls() if "--http-method" in c and c[c.index("--http-method") + 1] == "POST"]
        self.assertTrue(all(c[c.index("--resource") + 1] == "pullRequestThreads" for c in posts))
        self.assertFalse(any(c[:2] == ["repos", "pr"] and c[2] not in ("list", "show") for c in self.calls()))

    def test_post_refuses_a_wrong_head_file_or_line(self):
        self.remote_repo()
        self.checkout()
        ok = {"polarity": "Blocking", "file": "src/a.txt", "line": 30, "body": "x"}
        for docket, reason in ((self.docket([ok], head=self.first), "reviewed PR head"),
                               (self.docket([{**ok, "file": "src/missing.txt"}]), "does not exist at the PR head"),
                               (self.docket([{**ok, "line": 31}]), "past the end of the file"),
                               (self.docket([{**ok, "file": "/src/a.txt"}]), "repo-relative"),
                               (self.docket([{**ok, "polarity": "Major"}]), "polarity")):
            self.assertIn(reason, self.run_watch("post", self.key, docket, code=1).stderr)
        self.assertEqual(self.load()["threads"].get("repo-Webshop/7", []), [])

    def test_post_names_a_missing_or_broken_docket(self):
        self.remote_repo()
        self.checkout()
        self.assertIn("no file at", self.run_watch("post", self.key, str(self.root / "nope.json"), code=1).stderr)
        bad = self.root / "bad.json"
        bad.write_text("{not json")
        self.assertIn("not valid JSON", self.run_watch("post", self.key, str(bad), code=1).stderr)

    def test_post_caps_inline_comments_and_dry_run_posts_nothing(self):
        self.remote_repo()
        self.checkout()
        items = [{"polarity": "Should fix", "file": "src/a.txt", "line": n, "body": "issue %d" % n} for n in range(1, 14)]
        dry = json.loads(self.run_watch("post", self.key, self.docket(items), "--dry-run").stdout)
        self.assertEqual(len(dry["inline"]), 10)
        self.assertIn("issue 13", dry["summary"]["comments"][0]["content"])
        self.assertEqual(self.load()["threads"].get("repo-Webshop/7", []), [])

    def test_post_refuses_a_pr_that_became_a_draft(self):
        self.remote_repo()
        self.checkout()
        self.az_state["prs"][ORG + "|Webshop"][0]["isDraft"] = True
        self.save()
        self.assertIn("no longer active and ready", self.run_watch("post", self.key, self.docket([]), code=1).stderr)

    def test_a_pr_under_review_is_not_offered_again(self):
        self.remote_repo()
        self.assertEqual(len(json.loads(self.run_watch("candidates").stdout)), 1)
        self.checkout()
        self.assertEqual(json.loads(self.run_watch("candidates").stdout), [])
        self.run_watch("cleanup", self.key)
        self.assertEqual(len(json.loads(self.run_watch("candidates").stdout)), 1)

    def test_cleanup_removes_the_worktree(self):
        self.remote_repo()
        tree = Path(self.checkout()["worktree"])
        self.run_watch("cleanup", self.key)
        self.assertFalse(tree.exists())

    # ------------------------------------------------------------------ review

    def review(self, **env):
        out = self.run_watch("review", self.key, **env).stdout
        return json.loads(out.strip().splitlines()[-1])

    def test_review_runs_nine_heads_and_an_opus_judge_that_posts(self):
        self.remote_repo()
        row = self.review()
        self.assertEqual(row["status"], "reviewed", row)
        self.assertEqual(row["judge"]["model"], "claude-opus-5-5")
        self.assertEqual(row["judge"]["costUsd"], 0.42)
        self.assertEqual(row["judge"]["lastLine"], "REVIEWED approved-with-comments 1")
        self.assertEqual(len(row["heads"]), 9)
        claude = json.loads((self.root / "claude.json").read_text())
        argv = claude["argv"]
        opt = lambda name: argv[argv.index(name) + 1]
        self.assertEqual((opt("--model"), opt("--effort"), opt("--autocompact")), ("claude-opus-5-5", "medium", "500k"))
        self.assertEqual(opt("--permission-mode"), "acceptEdits")
        self.assertNotIn("--max-budget-usd", argv)
        tools = argv[argv.index("--allowedTools") + 1:]
        self.assertTrue(any(t.startswith("Bash(python3 ") and t.endswith(" post:*)") for t in tools))
        self.assertFalse(any(t in ("Bash", "Write", "Edit") or "push" in t for t in tools))
        self.assertIsNone(claude["host"])
        self.assertIsNone(claude["effortEnv"])
        scope = Path(row["judge"]["log"][:-len(".judge.jsonl")])
        self.assertTrue(Path(claude["cwd"]).name.endswith("-pr7"))
        self.assertEqual(Path(argv[argv.index("--add-dir") + 1]).resolve(), scope.resolve())
        self.assertIn("Bash(git diff:*)", tools)
        self.assertFalse(any("-C" in t for t in tools))
        self.assertEqual((scope / "heads/requested.txt").read_text().strip(),
                         "delivery,dependency,identity,parity,situate,reach,falsify,conform,invariants")
        self.assertIn("review-watch head " + self.head, self.load()["threads"]["repo-Webshop/7"][-1]["comments"][0]["content"])
        self.assertFalse(list((self.root / "home/worktrees").iterdir()))
        self.assertEqual(json.loads(self.run_watch("candidates").stdout), [])
        again = self.review()
        self.assertEqual((again["status"], again["reason"]), ("skipped", "this head is already reviewed"))

    def test_a_judge_that_does_not_post_is_a_failure(self):
        self.remote_repo()
        for count in (1, 2):
            row = self.review(FAKE_CLAUDE_MODE="nopost")
            self.assertEqual((row["status"], row["failures"]), ("failed", count))
            self.assertIn("FAILED could not verify", row["reason"])
        self.assertEqual(json.loads(self.run_watch("candidates").stdout), [])

    def test_no_head_output_fails_before_the_judge(self):
        self.remote_repo()
        row = self.review(FAKE_HEADS_MODE="fail")
        self.assertEqual(row["status"], "failed")
        self.assertIn("no Codex head produced output", row["reason"])
        self.assertFalse((self.root / "claude.json").exists())

    def test_a_too_large_pr_gets_a_summary_and_no_review(self):
        self.remote_repo()
        cfg_path = self.root / "home/config.json"
        cfg = json.loads(cfg_path.read_text())
        cfg["maxFiles"] = 1
        cfg_path.write_text(json.dumps(cfg))
        row = self.review()
        self.assertEqual(row["status"], "too-big")
        summary = self.load()["threads"]["repo-Webshop/7"][-1]["comments"][0]["content"]
        self.assertIn("Not reviewed automatically", summary)
        self.assertFalse((self.root / "claude.json").exists())

    def test_review_settings_are_configurable_and_checked(self):
        cfg = json.loads(self.run_watch("setup", ORG + "/Webshop", "--model", "claude-sonnet-5-5", "--effort", "high",
                                        "--context-cap", "300k", "--max-budget-usd", "3", "--heads", "delivery,conform").stdout)
        self.assertEqual((cfg["reviewModel"], cfg["reviewEffort"], cfg["contextCap"], cfg["maxBudgetUsd"], cfg["heads"]),
                         ("claude-sonnet-5-5", "high", "300k", 3.0, ["delivery", "conform"]))
        self.assertIn("--heads takes names", self.run_watch("setup", ORG + "/Webshop", "--heads", "delivery,bogus", code=1).stderr)
        self.assertIn("--effort", self.run_watch("setup", ORG + "/Webshop", "--effort", "huge", code=1).stderr)
        self.assertIn("--context-cap", self.run_watch("setup", ORG + "/Webshop", "--context-cap", "lots", code=1).stderr)

    def test_a_spend_cap_reaches_the_judge(self):
        self.remote_repo()
        self.run_watch("setup", ORG + "/Webshop", "--max-budget-usd", "2.5")
        self.review()
        argv = json.loads((self.root / "claude.json").read_text())["argv"]
        self.assertEqual(argv[argv.index("--max-budget-usd") + 1], "2.5")
        self.assertEqual(argv[argv.index("--model") + 1], "claude-opus-5-5")


if __name__ == "__main__":
    unittest.main()
