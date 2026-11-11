#!/usr/bin/env python3
"""Azure DevOps pull-request watcher for review-panel. Standard library only;
it calls `az` and `git`. Subcommands:

  setup <url> [<url> ...] [--me <id>] [--skip <author>] ...
                                           save the projects to watch (asks nothing)
  show                                     print the saved config
  check                                    az login and config check
  candidates                               one pass: PRs to review now, as JSON
  poll [--once] [--now ISO] [--max-cycles N]
                                           wait (no model) until a PR needs review,
                                           print CANDIDATES <json> and exit 0
  checkout <key> [--previous <sha>]        clone/fetch and a detached worktree at the PR head
  threads <key>                            the PR's existing comment threads, compact
  post <key> <docket.json> [--dry-run]     post the inline threads and the marked summary
  fail <key> <head> <reason>               record a failed review of that head
  cleanup <key>                            remove the PR worktree
  review <key> [<key> ...]                 the whole review of each PR: checkout,
                                           scope, Codex heads (no model), then a
                                           headless Claude judge that posts; one
                                           JSON line per PR

A key is org/project/repositoryId/pullRequestId. Exit codes: 0 ok, 1 error,
2 az is not logged in, 3 repeated az failures while polling, 4 another session
is already watching (one poller per machine).
Home: $REVIEW_WATCH_HOME, default ~/.claude/review-watch (config.json,
state.json, repos/, worktrees/).
"""
import argparse
import fcntl
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

MARKER = "review-watch head "
MARKER_RE = re.compile(r"review-watch head ([0-9a-f]{40})")
POLARITIES = ("Blocking", "Should fix", "Nit", "FYI")
INLINE = ("Blocking", "Should fix")
DEFAULTS = {"intervalSeconds": 1800, "days": [1, 2, 3, 4, 5], "hours": [8, 18],
            "maxComments": 10, "maxFiles": 60, "maxLines": 3000, "maxFailures": 2,
            "apiVersion": "7.1",
            # The judge: a headless Claude Code run per PR (Desktop cannot start
            # a session from a turn a background task woke). contextCap is its
            # auto-compact window; maxBudgetUsd an optional spend cap per PR.
            "reviewModel": "claude-opus-5-5", "reviewEffort": "medium", "contextCap": "500k",
            "maxBudgetUsd": None, "reviewTimeoutMinutes": 60,
            # The finders: review-panel deep mode, one Codex run per head.
            "heads": ["delivery", "dependency", "identity", "parity", "situate", "reach", "falsify",
                      "conform", "invariants"],
            "headsTimeoutMinutes": 20}
SKILL_DIR = Path(__file__).resolve().parents[1]
JUDGE_PROMPT = SKILL_DIR / "judge-prompt.md"
PANEL_SKILL = SKILL_DIR.parent / "review-panel" / "SKILL.md"


def panel_scripts():
    return Path(os.environ.get("REVIEW_WATCH_PANEL_SCRIPTS") or SKILL_DIR.parent / "review-panel" / "scripts")


class Stop(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def home():
    return Path(os.environ.get("REVIEW_WATCH_HOME") or Path.home() / ".claude" / "review-watch")


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    os.replace(tmp, path)


def config():
    cfg = read_json(home() / "config.json")
    if not cfg or not cfg.get("projects"):
        raise Stop("no config: run the configure-prs skill once with your Azure DevOps project URL")
    return {**DEFAULTS, **cfg}


# ---------------------------------------------------------------- Azure DevOps

def az(*args, input_file=None):
    argv = ["az", *args, "-o", "json"]
    if input_file:
        argv += ["--in-file", str(input_file)]
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        err = result.stderr.strip()
        if "login" in err.lower() and ("az login" in err or "az devops login" in err):
            raise Stop("az is not logged in: run `az login` (or `az devops login`) in a terminal", 2)
        raise Stop("az " + " ".join(args[:3]) + " failed: " + err[:500])
    out = result.stdout.strip()
    return json.loads(out) if out else None


def parse_url(url):
    """https://dev.azure.com/{org}/{project}[/_git/{repo}...] or
    https://{org}.visualstudio.com/{project}[/_git/{repo}...], user info allowed."""
    parts = urllib.parse.urlsplit(url.strip())
    host = (parts.hostname or "").lower()
    segments = [urllib.parse.unquote(s) for s in parts.path.split("/") if s]
    if host == "dev.azure.com":
        if len(segments) < 2:
            raise Stop("not a project URL (want https://dev.azure.com/<org>/<project>): " + url)
        org, rest = segments[0], segments[1:]
    elif host.endswith(".visualstudio.com"):
        if not segments:
            raise Stop("not a project URL (want https://<org>.visualstudio.com/<project>): " + url)
        org, rest = host.split(".")[0], segments
    else:
        raise Stop("not an Azure DevOps URL: " + url)
    project = rest[0]
    if project.startswith("_"):
        raise Stop("the URL names no project: " + url)
    repo = rest[2] if len(rest) >= 3 and rest[1] == "_git" else None
    return {"org": org, "orgUrl": "https://dev.azure.com/" + org, "project": project, "repo": repo}


def pr_url(c):
    return "{}/{}/_git/{}/pullrequest/{}".format(c["orgUrl"], urllib.parse.quote(c["project"]),
                                                 urllib.parse.quote(c["repo"]), c["prId"])


def key_of(pr, project):
    return "/".join([project["org"], project["project"], pr["repository"]["id"], str(pr["pullRequestId"])])


def split_key(key):
    parts = key.split("/")
    if len(parts) != 4 or not parts[3].isdigit():
        raise Stop("a key is org/project/repositoryId/pullRequestId: " + key)
    return {"org": parts[0], "orgUrl": "https://dev.azure.com/" + parts[0], "project": parts[1],
            "repoId": parts[2], "prId": int(parts[3])}


def threads(k, cfg):
    data = az("devops", "invoke", "--org", k["orgUrl"], "--area", "git", "--resource", "pullRequestThreads",
              "--route-parameters", "project=" + k["project"], "repositoryId=" + k["repoId"],
              "pullRequestId=" + str(k["prId"]), "--http-method", "GET", "--api-version", cfg["apiVersion"])
    return data.get("value", []) if isinstance(data, dict) else (data or [])


def markers(thread_list):
    found = []
    for thread in thread_list:
        for comment in thread.get("comments", []):
            for sha in MARKER_RE.findall(comment.get("content") or ""):
                found.append((comment.get("publishedDate") or "", sha))
    return [sha for _, sha in sorted(found)]


def mine(pr, cfg):
    who = pr.get("createdBy") or {}
    ids = {str(x).lower() for x in cfg.get("me", [])}
    return bool(ids & {str(who.get("id", "")).lower(), str(who.get("uniqueName", "")).lower()})


def bot(pr, cfg):
    """A pipeline or service identity (Build Service, a service connection), or
    an author in skipAuthors. Their PRs get no review."""
    who = pr.get("createdBy") or {}
    unique = str(who.get("uniqueName", ""))
    if str(who.get("descriptor", "")).startswith("svc.") or unique.lower().startswith("build\\"):
        return True
    skip = {str(x).lower() for x in cfg.get("skipAuthors", [])}
    return bool(skip & {unique.lower(), str(who.get("id", "")).lower(), str(who.get("displayName", "")).lower()})


def pr_show(k):
    return az("repos", "pr", "show", "--id", str(k["prId"]), "--org", k["orgUrl"])


# --------------------------------------------------------------------- state

CLAIM_SECONDS = 2 * 3600


def state():
    st = read_json(home() / "state.json", {}) or {}
    for name in ("failures", "posted", "claims"):
        st.setdefault(name, {})
    return st


def claimed(st, key, head):
    """A head under review by a session (checkout until post, fail or cleanup).
    A claim older than two hours is stale: that review died."""
    at = st["claims"].get(key, {}).get(head)
    return bool(at) and time.time() - at < CLAIM_SECONDS


def set_claim(key, head, on):
    st = state()
    if on:
        st["claims"].setdefault(key, {})[head] = time.time()
    else:
        st["claims"].pop(key, None)
    write_json(home() / "state.json", st)


def failures(st, key, head):
    return st["failures"].get(key, {}).get(head, 0)


# ------------------------------------------------------------------ commands

def cmd_setup(args):
    # One entry per org/project. A repo URL narrows it to that repo; a project
    # URL (no repo) watches every repo of the project.
    by_project = {}
    for url in args.urls:
        p = parse_url(url)
        entry = by_project.setdefault((p["org"], p["project"]), {
            "org": p["org"], "orgUrl": p["orgUrl"], "project": p["project"], "repos": []})
        if p["repo"] is None:
            entry["repos"] = None
        elif entry["repos"] is not None and p["repo"] not in entry["repos"]:
            entry["repos"].append(p["repo"])
    projects = list(by_project.values())
    me = [m for m in (args.me or []) if m]
    if not me:
        account = az("account", "show")
        user = ((account or {}).get("user") or {}).get("name")
        if not user:
            raise Stop("could not read your identity from `az account show`; pass --me <email>")
        me = [user]
    old = read_json(home() / "config.json", {}) or {}
    cfg = {**DEFAULTS, **{k: v for k, v in old.items() if k in DEFAULTS}, "projects": projects,
           "me": [m.lower() for m in me], "skipAuthors": [a.lower() for a in (args.skip or [])]}
    if args.hours:
        start, end = (int(x) for x in args.hours.split("-"))
        if not 0 <= start < end <= 24:
            raise Stop("--hours is start-end, for example 8-18")
        cfg["hours"] = [start, end]
    for name, value in (("reviewModel", args.model), ("reviewEffort", args.effort),
                        ("contextCap", args.context_cap), ("maxBudgetUsd", args.max_budget_usd)):
        if value is not None:
            cfg[name] = value
    if cfg["reviewEffort"] not in ("low", "medium", "high", "xhigh", "max"):
        raise Stop("--effort is low, medium, high, xhigh or max")
    if not re.fullmatch(r"\d+k|\d+", str(cfg["contextCap"])):
        raise Stop("--context-cap is a token count such as 500k")
    if args.heads:
        known = {h.stem for h in (SKILL_DIR.parent / "review-panel" / "heads").glob("*.md") if not h.stem.startswith("_")}
        heads = [h.strip() for h in args.heads.split(",") if h.strip()]
        unknown = [h for h in heads if h not in known]
        if unknown or not heads:
            raise Stop("--heads takes names from: " + ", ".join(sorted(known)))
        cfg["heads"] = heads
    if args.interval:
        if args.interval < 300:
            raise Stop("--interval is at least 300 seconds")
        cfg["intervalSeconds"] = args.interval
    write_json(home() / "config.json", cfg)
    print(json.dumps(cfg, indent=2))


def cmd_show(args):
    print(json.dumps(config(), indent=2))


def cmd_check(args):
    cfg = config()
    account = az("account", "show")
    for p in cfg["projects"]:
        az("repos", "pr", "list", "--org", p["orgUrl"], "--project", p["project"], "--status", "active", "--top", "1")
    print(json.dumps({"ok": True, "account": ((account or {}).get("user") or {}).get("name"),
                      "projects": [p["org"] + "/" + p["project"] for p in cfg["projects"]]}))


def find_candidates(cfg):
    st = state()
    out = []
    for p in cfg["projects"]:
        repos = p.get("repos") or [None]
        for repo in repos:
            argv = ["repos", "pr", "list", "--org", p["orgUrl"], "--project", p["project"],
                    "--status", "active", "--top", "200"]
            if repo:
                argv += ["--repository", repo]
            for pr in az(*argv) or []:
                if pr.get("isDraft") or mine(pr, cfg) or bot(pr, cfg):
                    continue
                head = (pr.get("lastMergeSourceCommit") or {}).get("commitId")
                if not head:
                    continue
                key = key_of(pr, p)
                if failures(st, key, head) >= cfg["maxFailures"] or claimed(st, key, head):
                    continue
                k = split_key(key)
                done = markers(threads(k, cfg))
                if head in done:
                    continue
                c = {"key": key, "org": p["org"], "orgUrl": p["orgUrl"], "project": p["project"],
                     "repo": pr["repository"]["name"], "repoId": pr["repository"]["id"],
                     "prId": pr["pullRequestId"], "title": pr.get("title", ""),
                     "author": (pr.get("createdBy") or {}).get("displayName", ""),
                     "source": pr.get("sourceRefName"), "target": pr.get("targetRefName"),
                     "head": head, "previousHead": done[-1] if done else None}
                c["url"] = pr_url(c)
                out.append(c)
    return out


def cmd_candidates(args):
    print(json.dumps(find_candidates(config()), indent=2))


def in_window(now, cfg):
    start, end = cfg["hours"]
    return now.isoweekday() in cfg["days"] and start <= now.hour < end


def seconds_to_window(now, cfg):
    probe = now.replace(minute=0, second=0, microsecond=0)
    for _ in range(24 * 8):
        probe += dt.timedelta(hours=1)
        if in_window(probe, cfg):
            return max(60, int((probe - now).total_seconds()))
    return cfg["intervalSeconds"]


def cmd_poll(args):
    cfg = config()
    home().mkdir(parents=True, exist_ok=True)
    lock = (home() / "poll.lock").open("a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Stop("ALREADY WATCHING: another session's poller runs on this machine; stop it there first", 4)
    errors, cycles = 0, 0
    while True:
        cycles += 1
        now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now()
        if in_window(now, cfg):
            try:
                found = find_candidates(cfg)
                errors = 0
            except Stop as error:
                if error.code == 2:
                    raise
                errors += 1
                print("poll: " + str(error), file=sys.stderr, flush=True)
                if errors >= 3:
                    raise Stop("3 failed polls in a row: " + str(error), 3)
                found = []
            if found:
                print("CANDIDATES " + json.dumps(found), flush=True)
                return
            wait = cfg["intervalSeconds"]
        else:
            wait = min(cfg["intervalSeconds"], seconds_to_window(now, cfg))
        if args.once or (args.max_cycles and cycles >= args.max_cycles):
            print("NONE", flush=True)
            return
        time.sleep(wait)


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def safe(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "x"


def worktree_dir(k, repo):
    return home() / "worktrees" / "-".join(safe(x) for x in (k["org"], k["project"], repo, "pr" + str(k["prId"])))


def checkout(key, previous=None):
    cfg = config()
    k = split_key(key)
    pr = pr_show(k)
    repo = pr["repository"]["name"]
    head = pr["lastMergeSourceCommit"]["commitId"]
    remote = os.environ.get("REVIEW_WATCH_CLONE_URL") or pr["repository"]["remoteUrl"]
    clone = home() / "repos" / safe(k["org"]) / safe(k["project"]) / safe(repo)
    if not (clone / ".git").exists():
        clone.parent.mkdir(parents=True, exist_ok=True)
        git("clone", "--quiet", "--no-checkout", remote, str(clone))
    target = pr["targetRefName"]
    short = target[len("refs/heads/"):] if target.startswith("refs/heads/") else target
    git("fetch", "--quiet", "origin", "+{}:refs/remotes/origin/{}".format(target, short),
        "+{}:refs/review-watch/pr-{}".format(pr["sourceRefName"], k["prId"]), cwd=clone)
    try:
        git("cat-file", "-e", head + "^{commit}", cwd=clone)
    except subprocess.CalledProcessError:
        raise Stop("the PR head {} is not on its source branch any more; it will be picked up again".format(head[:12]))
    tree = worktree_dir(k, repo)
    if tree.exists():
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=clone, capture_output=True)
    git("worktree", "prune", cwd=clone)
    git("worktree", "add", "--quiet", "--detach", str(tree), head, cwd=clone)
    set_claim(key, head, True)
    base = git("merge-base", "origin/" + short, head, cwd=clone)
    range_base = base
    if previous:
        ok = subprocess.run(["git", "merge-base", "--is-ancestor", previous, head], cwd=clone,
                            capture_output=True).returncode == 0
        if ok:
            range_base = previous
    stat = git("diff", "--numstat", range_base, head, cwd=clone).splitlines()
    lines = sum(int(a) + int(b) for a, b, _ in (row.split("\t", 2) for row in stat) if a.isdigit() and b.isdigit())
    too_big = len(stat) > cfg["maxFiles"] or lines > cfg["maxLines"]
    return {"worktree": str(tree), "clone": str(clone), "repo": repo, "head": head, "base": base,
            "rangeBase": range_base, "delta": range_base != base, "files": len(stat),
            "changedLines": lines, "tooBig": too_big, "target": "origin/" + short}


def cmd_checkout(args):
    print(json.dumps(checkout(args.key, args.previous), indent=2))


def cmd_threads(args):
    cfg = config()
    k = split_key(args.key)
    rows = []
    for t in threads(k, cfg):
        comments = [c for c in t.get("comments", []) if c.get("commentType") != "system"]
        if not comments or t.get("isDeleted"):
            continue
        ctx = t.get("threadContext") or {}
        start = (ctx.get("rightFileStart") or {}).get("line")
        rows.append({"id": t.get("id"), "status": t.get("status"),
                     "where": (ctx.get("filePath") or "") + (":" + str(start) if start else ""),
                     "comments": [{"by": (c.get("author") or {}).get("displayName"),
                                   "text": (c.get("content") or "")[:600]} for c in comments]})
    print(json.dumps(rows, indent=2))


def fingerprint(item):
    return "{}:{}:{}".format(item["file"], item.get("line"), re.sub(r"\s+", " ", item["body"])[:80])


def need(ok, message):
    if not ok:
        raise Stop("docket: " + message)


def validate(docket, tree, head):
    need(isinstance(docket, dict) and docket.get("head") == head, "head must be the reviewed PR head " + head)
    need(isinstance(docket.get("summary"), str) and docket["summary"].strip(), "summary text is required")
    items = docket.get("items", [])
    need(isinstance(items, list), "items must be a list")
    for item in items:
        need(isinstance(item, dict) and item.get("polarity") in POLARITIES, "item polarity must be one of " + ", ".join(POLARITIES))
        need(isinstance(item.get("body"), str) and item["body"].strip(), "item body is required")
        need(isinstance(item.get("file"), str) and item["file"] and not item["file"].startswith("/"),
             "item file is a repo-relative path")
        line, end = item.get("line"), item.get("endLine", item.get("line"))
        need(type(line) is int and type(end) is int and 1 <= line <= end, "item line/endLine are positive and ordered")
        try:
            text = subprocess.run(["git", "show", head + ":" + item["file"]], cwd=tree, capture_output=True,
                                  text=True, check=True).stdout
        except subprocess.CalledProcessError:
            raise Stop("docket: {} does not exist at the PR head".format(item["file"]))
        need(end <= max(1, len(text.splitlines())), "{}:{} is past the end of the file".format(item["file"], end))
    return items


def post(key, docket_path, dry_run=False):
    cfg = config()
    k = split_key(key)
    pr = pr_show(k)
    head = pr["lastMergeSourceCommit"]["commitId"]
    tree = worktree_dir(k, pr["repository"]["name"])
    try:
        docket = read_json(docket_path)
    except ValueError as error:
        raise Stop("docket: {} is not valid JSON: {}".format(docket_path, error))
    if docket is None:
        raise Stop("docket: no file at {}; write it first".format(docket_path))
    items = validate(docket, tree, head)
    if pr.get("status") != "active" or pr.get("isDraft"):
        raise Stop("the PR is no longer active and ready; nothing posted")
    st = state()
    done = set(st["posted"].get(key, {}).get(head, []))
    inline = [i for i in items if i["polarity"] in INLINE]
    rest = [i for i in items if i["polarity"] not in INLINE]
    overflow = inline[cfg["maxComments"]:]
    inline = inline[:cfg["maxComments"]]
    payloads = []
    for item in inline:
        if fingerprint(item) in done:
            continue
        end = item.get("endLine", item["line"])
        payloads.append((fingerprint(item), {
            "comments": [{"parentCommentId": 0, "commentType": 1,
                          "content": "**{}**: {}".format(item["polarity"], item["body"].strip())}],
            "status": 1,
            "threadContext": {"filePath": "/" + item["file"],
                              "rightFileStart": {"line": item["line"], "offset": 1},
                              "rightFileEnd": {"line": end, "offset": 1}}}))
    lines = [docket["summary"].strip()]
    extra = overflow + rest
    if extra:
        lines.append("")
        lines += ["- **{}** `{}:{}`: {}".format(i["polarity"], i["file"], i["line"], i["body"].strip()) for i in extra]
    lines += ["", "<sub>Automated review: review-panel (Codex finder, Claude judge). It never votes. "
              + MARKER + head + "</sub>"]
    summary = {"comments": [{"parentCommentId": 0, "commentType": 1, "content": "\n".join(lines)}], "status": 4}
    if dry_run:
        return {"inline": [p for _, p in payloads], "summary": summary}
    route = ["--route-parameters", "project=" + k["project"], "repositoryId=" + k["repoId"],
             "pullRequestId=" + str(k["prId"])]
    for fp, payload in payloads:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(payload, f)
        try:
            az("devops", "invoke", "--org", k["orgUrl"], "--area", "git", "--resource", "pullRequestThreads",
               *route, "--http-method", "POST", "--api-version", cfg["apiVersion"], input_file=f.name)
        finally:
            os.unlink(f.name)
        st["posted"].setdefault(key, {}).setdefault(head, []).append(fp)
        write_json(home() / "state.json", st)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(summary, f)
    try:
        az("devops", "invoke", "--org", k["orgUrl"], "--area", "git", "--resource", "pullRequestThreads",
           *route, "--http-method", "POST", "--api-version", cfg["apiVersion"], input_file=f.name)
    finally:
        os.unlink(f.name)
    st["failures"].get(key, {}).pop(head, None)
    st["posted"].get(key, {}).pop(head, None)
    st["claims"].pop(key, None)
    write_json(home() / "state.json", st)
    return {"posted": len(payloads), "summary": True, "head": head,
            "url": pr_url({**k, "repo": pr["repository"]["name"]})}


def cmd_post(args):
    result = post(args.key, args.docket, args.dry_run)
    print(json.dumps(result, indent=2 if args.dry_run else None))


def fail(key, head, reason):
    st = state()
    count = st["failures"].setdefault(key, {}).get(head, 0) + 1
    st["failures"][key][head] = count
    st["claims"].pop(key, None)
    write_json(home() / "state.json", st)
    return {"key": key, "head": head, "failures": count, "reason": reason}


def cmd_fail(args):
    print(json.dumps(fail(args.key, args.head, args.reason)))


def cleanup(key):
    k = split_key(key)
    set_claim(key, None, False)
    removed = []
    for tree in (home() / "worktrees").glob("-".join(safe(x) for x in (k["org"], k["project"])) + "-*-pr" + str(k["prId"])):
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=tree, capture_output=True, text=True).stdout.strip()
        clone = Path(tree, common).resolve().parent if common else None
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=clone, capture_output=True)
        removed.append(str(tree))
    return removed


def cmd_cleanup(args):
    for tree in cleanup(args.key):
        print(json.dumps({"removed": tree}))


def run_bounded(argv, cwd, log, timeout, env=None, input_text=None):
    """Run with a wall-time bound; stop the whole process group on timeout."""
    with open(log, "w") as out:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=out, stderr=subprocess.STDOUT,
                                   stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                                   start_new_session=True, text=True)
        try:
            process.communicate(input_text, timeout=timeout)
        except subprocess.TimeoutExpired:
            for sig in (15, 9):
                try:
                    os.killpg(process.pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
                time.sleep(1)
            process.wait()
            return 124
        except BaseException:
            try:
                os.killpg(process.pid, 9)
            except (ProcessLookupError, PermissionError):
                pass
            raise
    return process.returncode


def run_panel(info, k, cfg, scope):
    """The no-model half: scope and the Codex heads (review-panel deep mode)."""
    tree = info["worktree"]
    p = panel_scripts()
    scope.parent.mkdir(parents=True, exist_ok=True)
    code = run_bounded([str(p / "prepare-scope.sh"), info["rangeBase"], info["head"], "--pr", str(k["prId"]),
                        "--out", str(scope)], tree, str(scope) + ".prepare.log", 600)
    if code != 0:
        raise Stop("prepare-scope.sh failed; see " + str(scope) + ".prepare.log")
    with (scope / "facts.md").open("a") as facts:
        facts.write("\n- Automated watch run (configure-prs): no upstream lookup was made. "
                    "Report a load-bearing upstream claim as a fact-sheet gap.\n")
    code = run_bounded([str(p / "run-heads.sh"), str(scope), "--deep", "--heads", ",".join(cfg["heads"])], tree,
                       str(scope) + ".heads.log", cfg["headsTimeoutMinutes"] * 60)
    status = scope / "heads" / "status.tsv"
    rows = [line.split("\t") for line in status.read_text().splitlines()[1:]] if status.exists() else []
    usable = [r[0] for r in rows if len(r) > 2 and r[1] == "0" and r[2].isdigit() and int(r[2]) > 0]
    if not usable:
        raise Stop("no Codex head produced output (exit {}); see {}.heads.log".format(code, scope))
    return {"heads": usable, "failedHeads": [r[0] for r in rows if r and r[0] not in usable]}


def judge_prompt(values):
    text = JUDGE_PROMPT.read_text()
    for name, value in values.items():
        text = text.replace("{{" + name + "}}", str(value))
    return text


def run_judge(info, k, cfg, scope, pr, panel):
    """The model half: one headless Claude Code run that judges and posts."""
    w = Path(__file__).resolve()
    tree = info["worktree"]
    docket = scope / "docket.json"
    prompt = judge_prompt({
        "URL": pr_url({**k, "repo": info["repo"]}), "TITLE": pr.get("title", ""),
        "AUTHOR": (pr.get("createdBy") or {}).get("displayName", ""), "KEY": "/".join(
            [k["org"], k["project"], k["repoId"], str(k["prId"])]),
        "HEAD": info["head"], "RANGE_BASE": info["rangeBase"], "DELTA": "yes" if info["delta"] else "no",
        "WORKTREE": tree, "SCOPE": scope, "DOCKET": docket, "W": w, "PANEL_SKILL": PANEL_SKILL,
        "HEADS": ", ".join(panel["heads"]), "FAILED_HEADS": ", ".join(panel["failedHeads"]) or "none",
        "MAX_COMMENTS": cfg["maxComments"]})
    # Claude Code reads `git -C <dir>` as git in another folder and blocks it,
    # so the judge runs in the checkout and gets plain read-only git commands.
    git_reads = ["Bash(git {}:*)".format(sub) for sub in ("diff", "show", "log", "grep", "blame", "ls-files")]
    argv = [os.environ.get("REVIEW_WATCH_CLAUDE", "claude"), "-p", "--model", cfg["reviewModel"],
            "--effort", cfg["reviewEffort"], "--autocompact", str(cfg["contextCap"]),
            "--permission-mode", "acceptEdits", "--add-dir", str(scope),
            "--output-format", "stream-json", "--verbose",
            "--append-system-prompt", "This is a non-interactive automated review run. Ignore personal "
            "instructions about session titles, task lists, overview panes or asking the user.",
            "--allowedTools", "Read", "Grep", "Glob",
            "Bash(python3 {} threads:*)".format(w), "Bash(python3 {} post:*)".format(w), *git_reads]
    if cfg.get("maxBudgetUsd"):
        argv[2:2] = ["--max-budget-usd", str(cfg["maxBudgetUsd"])]
    env = {name: value for name, value in os.environ.items()
           if name not in ("CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_SUBAGENT_MODEL")}
    log = str(scope) + ".judge.jsonl"
    # acceptEdits lets the judge write only in its working folders: the
    # throwaway checkout and the scope dir (the docket). `post` checks every
    # line against the commit, not the checkout. Only the listed commands run.
    code = run_bounded(argv, tree, log, cfg["reviewTimeoutMinutes"] * 60, env=env, input_text=prompt)
    result = {}
    for line in Path(log).read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            result["model"] = event.get("model")
        if event.get("type") == "result":
            result.update({"outcome": event.get("subtype"), "costUsd": event.get("total_cost_usd"),
                           "lastLine": (str(event.get("result") or "").strip().splitlines() or [""])[-1][:300]})
    result.update({"exitCode": code, "log": log})
    return result


def review_one(key, cfg):
    k = split_key(key)
    pr = pr_show(k)
    head = pr["lastMergeSourceCommit"]["commitId"]
    row = {"key": key, "url": pr_url({**k, "repo": pr["repository"]["name"]}), "title": pr.get("title", ""),
           "head": head}
    if pr.get("status") != "active" or pr.get("isDraft") or mine(pr, cfg) or bot(pr, cfg):
        return {**row, "status": "skipped", "reason": "not an active, ready PR by a teammate"}
    done = markers(threads(k, cfg))
    if head in done:
        return {**row, "status": "skipped", "reason": "this head is already reviewed"}
    scope = home() / "scopes" / "{}-pr{}-{}".format(safe(k["project"]), k["prId"], head[:12])
    try:
        info = checkout(key, done[-1] if done else None)
        if info["tooBig"]:
            scope.mkdir(parents=True, exist_ok=True)
            write_json(scope / "docket.json", {"head": head, "items": [], "summary": (
                "Not reviewed automatically: {} files and {} changed lines are above the limit of {} files "
                "or {} lines. Please ask a teammate for a review.").format(
                    info["files"], info["changedLines"], cfg["maxFiles"], cfg["maxLines"])})
            post(key, scope / "docket.json")
            return {**row, "status": "too-big", "files": info["files"], "changedLines": info["changedLines"]}
        panel = run_panel(info, k, cfg, scope)
        judged = run_judge(info, k, cfg, scope, pr, panel)
        if head not in markers(threads(k, cfg)):
            reason = "the judge did not post ({})".format(judged.get("lastLine") or judged.get("outcome") or "no result")
            return {**row, "status": "failed", "reason": reason, **panel, "judge": judged,
                    "failures": fail(key, head, reason)["failures"]}
        return {**row, "status": "reviewed", "delta": info["delta"], **panel, "judge": judged}
    except Stop as error:
        if error.code == 2:
            raise
        return {**row, "status": "failed", "reason": str(error), "failures": fail(key, head, str(error))["failures"]}
    except subprocess.CalledProcessError as error:
        reason = "{} failed: {}".format(" ".join(error.cmd[:3]), (error.stderr or "").strip()[:300])
        return {**row, "status": "failed", "reason": reason, "failures": fail(key, head, reason)["failures"]}
    finally:
        cleanup(key)


def cmd_review(args):
    cfg = config()
    for key in args.keys:
        print(json.dumps(review_one(key, cfg)), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("setup")
    p.add_argument("urls", nargs="+")
    p.add_argument("--me", action="append")
    p.add_argument("--skip", action="append", help="an author (email, id or display name) never reviewed")
    p.add_argument("--hours")
    p.add_argument("--model", help="judge model id, default claude-opus-5-5")
    p.add_argument("--effort", help="judge effort, default medium")
    p.add_argument("--context-cap", help="judge auto-compact window, default 500k")
    p.add_argument("--max-budget-usd", type=float, help="optional spend cap per PR for the judge")
    p.add_argument("--heads", help="comma-separated review-panel heads, default the 9")
    p.add_argument("--interval", type=int)
    sub.add_parser("show")
    sub.add_parser("check")
    sub.add_parser("candidates")
    p = sub.add_parser("poll")
    p.add_argument("--once", action="store_true")
    p.add_argument("--now")
    p.add_argument("--max-cycles", type=int)
    p = sub.add_parser("checkout")
    p.add_argument("key")
    p.add_argument("--previous")
    p = sub.add_parser("threads")
    p.add_argument("key")
    p = sub.add_parser("post")
    p.add_argument("key")
    p.add_argument("docket")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("fail")
    p.add_argument("key")
    p.add_argument("head")
    p.add_argument("reason")
    p = sub.add_parser("cleanup")
    p.add_argument("key")
    p = sub.add_parser("review")
    p.add_argument("keys", nargs="+")
    args = parser.parse_args()
    try:
        globals()["cmd_" + args.command](args)
    except Stop as error:
        print("watch: " + str(error), file=sys.stderr)
        sys.exit(error.code)
    except subprocess.CalledProcessError as error:
        print("watch: {} failed: {}".format(" ".join(error.cmd[:3]), (error.stderr or "").strip()[:500]), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
