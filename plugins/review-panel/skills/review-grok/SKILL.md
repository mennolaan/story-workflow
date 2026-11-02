---
name: review-grok
description: Pre-PR and PR review with Grok (xAI Grok Build CLI) as the finder, for reviewers without a Codex account or as a second model family next to review-panel. Same procedure, scope, fact sheet, review profile, judge and docket as review-panel; only the finder differs. Default mode runs one adversarial review bound to a findings schema; deep mode and plan reviews run the review-panel stance heads. No Claude subagents.
effort: high
---

# Review with Grok

Purpose: the review-panel review for a person who has Grok Build and no
Codex account, or a second sample from another model family on a change that
already had review-panel. Finding runs on Grok (zero Claude tokens);
judging runs in the main thread on the session model.

Paths: `scripts/`, `prompts/` and `schemas/` below are folders of
`${CLAUDE_PLUGIN_ROOT}/skills/review-grok/`. The review-panel skill is
`${CLAUDE_PLUGIN_ROOT}/skills/review-panel/`. Run every script by its
absolute path, in double quotes, from the repo under review.

## The procedure is the review-panel procedure

Read `${CLAUDE_PLUGIN_ROOT}/skills/review-panel/SKILL.md` and follow it step
by step: When, Input, the review profile, Narration, the procedure,
Presentation, After the panel, and the head library. This skill changes only
the finder. It uses the review-panel scripts, profile and head prompts
unchanged: `prepare-scope.sh` builds the scope, `check_scope_integrity`
guards it, `check-docket.sh` checks the docket, and `heads/*.md` with
`_preamble.md`, `_focus.md` and the profile are the finder instructions.
Replace these steps:

1. **Preconditions.** `scripts/grok.sh preflight`: the CLI is on PATH, its
   version is in `scripts/lib.sh` (`SUPPORTED_GROK_VERSIONS`), it is logged in,
   and one probe turn reports exactly the tools `read_file`, `grep` and
   `list_dir`. Absent: report exactly what is missing and stop. The other
   preconditions of review-panel step 1 apply as written.
4. **Find (Grok, background).**
   `scripts/run-grok.sh <scope-dir> [--deep] [--heads a,b,c] [--focus text]
   [--max-parallel n] [--timeout minutes]`.
   - Default mode: one adversarial review. The prompt is `prompts/no-shell.md`,
     `prompts/adversarial.md` and review-panel `heads/_focus.md` with the
     profile context. The result is bound to `schemas/findings.schema.json`
     and must pass `scripts/validate-findings.py`. Output:
     `findings.grok.json` and `findings.grok.log` in the scope dir.
   - Deep mode and every plan review: the review-panel stance heads, each
     behind `prompts/no-shell.md` and review-panel `heads/_preamble.md`. A plan
     scope always runs the heads, by default `planHeads` of the profile.
     Output: `heads/<head>.grok.out.md`, `.log` and `heads/status.grok.tsv`.
   Background the command and keep the main thread idle meanwhile. Grok runs
   are ephemeral and carry no memory between runs.
7. **Judge.** Read `findings.grok.json` (or the `*.grok.out.md` head outputs).
   Everything else in review-panel step 7 applies as written.

When the same change also had review-panel, the judge unions both result
sets by file, line and claim before the cross-off; agreement between the two
finders is still not evidence.

## How Grok runs

- **Read-only.** The tool allowlist is `read_file`, `grep` and `list_dir`;
  `Agent`, `search_tool` and `use_tool` are denied; web and subagents are off.
  Grok has no write tool and no shell. The adapter discards the output of a
  run that offered or called any other tool, and `check_tree_untouched` fails
  the run when the reviewed tree changed.
- **Isolated.** Every Grok process starts with HOME and GROK_HOME in a fresh
  private temp dir that holds only a symlink to `~/.grok/auth.json`. It loads
  no user config, plugin, MCP server, hook, skill or memory.
- **Reviewed tree.** Grok has no shell, so it cannot run the `git show` that
  the review-panel prompts ask for. `prompts/no-shell.md` tells it to read the
  same paths in its working directory, which is a detached worktree at the
  scope head (branch and plan reviews) or the repo (uncommitted reviews).
  Gitignored files such as a plan under `.plans/` are read by full path in the
  shared checkout. For `git log`, the runner writes the last 20 commits on the
  base ref of the profile that touch the scoped files to
  `grok-recent-commits.txt` in the scope dir.
- **Bounds.** At most 3 runs at once, 30 minutes and 40 turns per run. A run
  that hits a bound fails with no output. The first measurements (2026-10-05):
  10 to 14 turns and 8 to 13 minutes per head, 7 minutes for one adversarial
  review.
- **Model.** `grok-4.7`, always passed explicitly.
- **No kernel sandbox by default.** The built-in `read-only` profile refuses
  to start while `/var/run/docker.sock` is a symlink, as OrbStack makes it.
  `REVIEW_GROK_SANDBOX=<profile>` adds a profile where one applies. Grok
  refuses to start when a profile cannot apply.

## Setup

`curl -fsSL https://x.ai/cli/install.sh | bash`, then `grok login` with a
SuperGrok or X Premium+ account. The installed version must match
`SUPPORTED_GROK_VERSIONS` in `scripts/lib.sh`. Grok updates itself when it runs
interactively. After an update, re-verify the flags and events that `lib.sh`
names and bump the pin.

## Held-out checks of this harness

`${CLAUDE_PLUGIN_ROOT}/tests/review-panel-matrix.sh` runs the Grok guards with
a fake `grok`: an unpinned version, a probe stream that offers
`run_terminal_cmd`, a stream that calls a tool outside the allowlist, a stream
that ends without final text, and a result that does not match the schema
(missing key, extra key, wrong type, unknown stance, broken JSON). A timeout,
`--max-turns`, a sandbox profile that cannot apply and a file written into the
reviewed tree need a live run. The value check is a canary branch with seeded
defects (a token in a parameter file, a prompt change without a version bump,
personal data in a log line): on 2026-10-05 the default mode found all three.

## Cost and data

Grok runs on the reviewer's own SuperGrok or X Premium+ subscription: no bill
per call. The repo code under review goes to xAI. Confirm that the repo owner
allows that before the first run. The rate limits are not measured, hence the
cap of 3 parallel runs.
