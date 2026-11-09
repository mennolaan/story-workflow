---
name: review-panel
description: Pre-PR and PR review. One Codex adversarial review (the /codex:adversarial-review engine) over a prepared scope and fact sheet, judged by the main thread: every finding verified, severity owned by the judge, docket presented for the user, tree-bound review artifact. Deep mode runs Codex stance heads instead of one review. Plan files too. A per-repo review profile adds the project rules. No Claude subagents.
effort: high
---

# Review panel

Purpose: catch before the PR what external review would otherwise catch after
it, at a fixed cost. Finding runs on Codex (the other model family, zero Claude
tokens); judging runs in the main thread on the session model. Every finding
is verified by the judge before it is believed: the engine's known weaknesses
(it always returns findings, its verdict bar is asymmetric, one sample varies)
are corrected by the judge, not by more finders. This shape spends Claude
tokens only in the judge turn.

Paths: `scripts/` and `heads/` below are
`${CLAUDE_PLUGIN_ROOT}/skills/review-panel/scripts/` and
`${CLAUDE_PLUGIN_ROOT}/skills/review-panel/heads/`. Run every script by that
absolute path, in double quotes, from the repo under review.

## When

At the end of an implementation arc, before opening or updating a pull
request; when reviewing a branch or a pull request; and again after any
post-review change (the artifact is tree-bound and self-invalidates).

In a child session of `/story` (plan, implement, pr-review), "the user" in this procedure is the orchestrator: send each question, the depth choice and the docket to it with SendMessage, never with AskUserQuestion.

## Input

Free-text instructions: the subject (a commit, a base ref, a branch, a pull
request number, `uncommitted work`, `plan <path>`), optional focus text
(appended to the Codex focus), and optional `deep` (the Codex stance heads
from `heads/` instead of one adversarial review; for security or
compliance-critical surfaces). Examples:

- `/review-panel`: current repo, branch vs the base ref of the profile.
- `/review-panel uncommitted work`: working tree vs HEAD.
- `/review-panel PR 84`: the branch of pull request 84 against its target
  branch; the number is recorded in the scope for context.
- `/review-panel deep`: the stance-head variant.
- `/review-panel plan .plans/<slug>.md`: design review of a plan file
  (`prepare-scope.sh --plan`, then `run-heads.sh`, which runs the plan heads).

Resolve the arguments to an exact scope (base, head, file list) and echo it
before launching anything. On ambiguity, ask; never guess a tree. When the
invocation does not say `deep`, do not assume default: step 3 asks the user.

**The panel reads no pull request threads.** The finders must never see them:
prior feedback anchors a finder. When the subject is an open pull request, ask
the user for the existing threads, or read them with the CLI of the PR host
(`gh pr view <n> --comments` on GitHub), and hand them to the judge in step 6.

## The review profile

A repo tunes the panel with a review profile: the folder
`.claude/review-profile/` (or the folder that `REVIEW_PANEL_PROFILE` names).
Every file in it is optional. Without the folder the panel runs on its generic
prompts and reads CLAUDE.md and AGENTS.md for the repo rules.

| File | Read by | Holds |
|---|---|---|
| `profile.json` | the scripts | `name`, `baseRef` (for example `origin/development`), `prHost` (`auto`, `github`, `azure-repos`, `none`), `harnessPaths` (added to the defaults), `deepHeads`, `planHeads` |
| `context.md` | every finder | the project rules: invariants, locked decisions, what not to flag in this repo, who sees a defect |
| `judge.md` | the judge (you) | the checks that must be green, the severity order, where PR threads live, where declined findings are answered |
| `heads/<head>.md` | that head | project detail appended to the generic head, or a head of its own |

`scripts/profile.sh show` prints the resolved profile. The example profile
is `${CLAUDE_PLUGIN_ROOT}/profile.example/`.

## Model and effort policy

- Session: a high-capability model at `high`. This skill pins the judge turn
  to `high` via frontmatter; never run reviews from a `max` session.
- Finder: default mode uses Codex (`codex-companion.mjs adversarial-review`,
  read-only sandbox; effort and model as configured in `~/.codex/config.toml`).
  Deep mode and every plan review require `gpt-6.1-sol`: `run-heads.sh` passes
  it explicitly for every head and refuses any other `--model`. If unavailable,
  stop and report the failure; never substitute an older Sol or Astra. Effort
  remains configured independently. No
  Claude subagent is spawned anywhere in this procedure; the Agent, Workflow
  and /code-review tools are not part of it.
- Judge: the main thread. It reads `adversarial.json` (or the head outputs in
  deep mode), never Codex transcripts, and does at most one upstream check
  per load-bearing citation it has to verify.

## Narration

The user watches this run and cannot see the tool output. Narrate each stage
in one or two lines as it completes, in the chat, not only in a file: what was
probed and what came back, the exact base and head, when the finders launch
and when they return, and what the gap resolution changed. Give counts,
versions and names, never adjectives. A stage that found nothing says so.
Never announce a stage before it has run, and never report a check as passed
without the output that says it passed.

## Procedure

1. **Preconditions.** Run `scripts/profile.sh show` and read `judge.md` when
   it lists one; its instructions apply to every step below. Probe for codex
   (`codex --version`) and the plugin companion
   (`ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs`);
   both versions must be in `scripts/pins.sh` (bumping a pin re-verifies the
   runner's assumptions, dated). Absent: report exactly what is missing and
   stop. When the reviewer has no Codex account, `/review-grok` runs this same
   procedure with Grok as the finder. Working tree committed, and the checks
   for what changed are green: the checks that `judge.md` names, else the
   verification commands of the repo's CLAUDE.md or README. Refresh the base:
   `git fetch origin` and use the base ref of the profile rather than a stale
   local branch.
2. **Scope and fact sheet (once).**
   `scripts/prepare-scope.sh <base> <head> [--pr n]` (or `--uncommitted`, or
   `--plan <path>` for a design review; ignored files allowed) writes
   `.claude/.review/<label>/{scope.md,scope.env,diff.patch,files.txt,facts.md,heads/}`.
   `.claude/.review/` must be gitignored; the script warns when it is not.
   `scope.env` is the manifest (mode, base and head SHAs, patch digest): the
   runners take their target from it and refuse a drifted checkout. When the
   candidate changes the review harness itself (the review profile,
   `.claude/settings.json`, CLAUDE.md, AGENTS.md, or a `harnessPaths` entry)
   the scope says so (`HARNESS_CHANGED=1`): read those hunks first; the
   profile and the repo rules the finders read come from the checkout under
   review.
   Fill `facts.md`: verify every listed pin and every load-bearing upstream
   fact against its live source (package registry, vendor documentation, the
   cloud resource itself, the model deployment list), each dated
   `as of YYYY-MM-DD` with the URL or path. Model ids, prices, quota numbers
   and SDK behaviours are the ones that bite. This is the single
   upstream-verification pass; Codex has no network and cites the sheet,
   reporting "unverified (fact-sheet gap)" where it is silent. Check the file
   list in `scope.md` against the expected scope.
   **Trace every changed setting to its other consumers.** For each option,
   app setting, flag or constant the diff changes, grep the repo for the other
   readers and record each in `facts.md`. Verifying that a change achieves its
   intended effect is not the same as knowing what else it moves: one shared
   client pinned to one model deployment can silently move every other caller
   of that client to the same model.
3. **Confirm the depth.** Ask the user for default or deep, with a
   recommendation and the reason. Default is one Codex review; deep is the
   stance heads, and its cost lands in the judge turn that unions and verifies
   every head's findings. A small, well-covered change argues for default; a
   thin review history on a security, personal-data or cost surface argues
   for deep. Do not launch until the user has chosen, unless the invocation
   already said which.
4. **Find (Codex, background).** Default:
   `scripts/run-adversarial.sh <scope-dir>` (verifies the manifest: diff
   digest, checkout at the scope head, scoped files clean in branch mode,
   working tree unchanged since preparation in uncommitted mode; target from
   `scope.env`, `--base` only in branch mode because the engine lets `--base`
   win over `--scope working-tree`; renders `heads/_focus.md` with the profile
   context as the review focus, runs the adversarial review with
   `--wait --json`, writes `adversarial.json` and `adversarial.log`, logs the
   companion and codex versions and the target the engine reports, prints
   verdict and finding count, refuses an engine target that does not match
   the manifest, fails loud). Deep, and every plan review:
   `scripts/run-heads.sh <scope-dir> [--heads a,b,c]` (heads from `heads/*.md`
   plus the profile heads, behind `heads/_preamble.md`, parallel,
   `heads/<head>.out.md` plus `status.tsv`; the default set is `deepHeads`,
   or `planHeads` for a plan scope; a plan file is not a git target for the
   adversarial engine; every Codex head is pinned to `gpt-6.1-sol`).
   Background the command and keep the main thread idle meanwhile. Codex runs
   are ephemeral: never resumed for a second pass with the same prompt.
5. **Resolve the fact-sheet gaps (blocking).** Collect every
   `unverified (fact-sheet gap)` line the heads emitted. Resolve each against
   primary source and append the verdict to `facts.md` with its citation and
   the date. Primary source is the dependency's own documentation or source at
   that version, a file in this repo at the reviewed tree, a live read of the
   resource, or a command whose output is in this transcript. Search-result
   prose is not primary source; a recollection is not; another head agreeing
   is not. A gap is never resolved by reasoning about it. Judge only after
   this step.
6. **Cross off what was already raised.** If the user supplied the pull
   request's existing threads (or you read them), reconcile the findings
   against them now, after the finders have returned. Classify each prior
   thread:

   - **addressed at the reviewed tree** (a commit changed those lines after
     the comment): cross the matching finding off silently, it is not new.
   - **declined with no fix and no reply**: the author's standing decision.
     One line in the closing footnote, no severity, never in the docket body.
     Two things put it back in the body: it belongs to a never-suppressed
     class (personal data reaching a model call, a log or an artifact; a
     secret in the repo or a log; an authorization check that can be
     bypassed; a paid path that runs unasked), or three or more footnote
     items damage the SAME guarantee, in which case write ONE body item
     naming the pattern.
   - **answered or declined in the thread**: the reply carries the reason;
     cross it off and do not re-argue it.

   Only findings left after the cross-off go forward. With no threads
   supplied, say so in the narration rather than implying the change had no
   prior review.
7. **Judge (main thread).** Union and dedup the findings by file/line and
   claim overlap; discard the engine's severity and verdict at the door. For
   each finding, presume it false and try to kill it against the repo at the
   reviewed tree and the fact sheet; verify the load-bearing citation
   yourself (reviewer web search is not grounding; one fetch per finding at
   most). **Promotion gate:** a finding may not be presented above Footnote
   unless its load-bearing fact was verified at primary source in this
   session, per step 5. A finding that survives only on the agreement of
   several heads has not been verified: correlated finders share blind spots,
   and unanimity is not evidence. Survivors get severity from their own
   failure scenario on four axes: preconditions (an attack requiring an
   already-compromised subscription owner is never high), blast radius
   (personal-data exposure or a wrong result shown to a user > an internal
   wedge > a test gap > docs; `judge.md` may name the project's order),
   loudness (a silent wrong result outranks a loud failure), scale realism
   (small-scale preconditions discount, with the revisit trigger named).
   A finding that cannot state its trigger is excluded. Conformance deltas
   score on their own scale, act-now (EOL, CVE, removal announced, a model id
   that does not exist, doc contradiction with behavioral consequence) or
   backlog-with-named-trigger. A guard for a case that cannot occur is a
   defect, not a finding. Classify: fix now, reject with reason, or decision
   for the user.
   **Second control on every accepted security finding.** When a finding
   closes an input path, ask where that input is still recorded, forwarded or
   stored, and carry the answer into the fix. Closing the door is not the same
   as clearing the room: moving a token back into the secret store does not
   rotate the token that is already in the git history, and a redaction added
   at the prompt does not clean the cached artifact that already holds the
   raw span.
   **Every accepted finding is a class, not a site.** Before you close an
   item, name the invariant it asserts and sweep the repo for every other
   place that invariant must hold (the other implementations of the same
   kind, the other endpoints, the client-side copy of a server-side
   threshold). List the sites in the item. The sweep is grep-scale and it is
   the cheapest coverage in this procedure.

## Presentation (the panel always ends here)

The docket, for the user to eyeball; nothing is implemented until the user
says so. Brief, curt, simple English. One line per finding: severity,
file:line, what is wrong, why it matters, the proposed fix. Grouped: fix now,
decision for you, refuted by the judge (count).

When prior threads were supplied, close with **Previously raised, standing as
declined (N)**: the step 6 footnote, one line each, the thread reference and
one clause of what it was. No severity, no argument. End that section with
"A one-line reply in each thread removes these from every future run."

A clean result states what it is and never implies more. Not "nothing to
change", but: this run found nothing it would defend. One run is one sample:
re-runs return different findings at similar counts, so a quiet panel means
the change survived this sample, not that it is correct. The held-out check
decides that.

Every item carries an explicit polarity: **Blocking**, **Should fix**,
**Nit**, or **FYI**. An unlabelled item reads as mandatory; label all of
them. Close the docket with one verdict, biased toward approval:

| Condition | Verdict |
|---|---|
| No findings, or Nit and FYI only | approved |
| Should-fix items, no production risk | approved with comments |
| Several Should-fix items forming one risk pattern | author decides |
| Any Blocking item | fix before merge |

One Should-fix in an otherwise clean change is "approved with comments",
never a block. A clean panel is a correct result, not a failed one: the
standard is that the change definitely improves the code health of the
system, not that it is perfect.

For a plan review the docket is also written into the plan file as a
`## Review` section: one line per finding with the verdict (accepted, with
the plan change it caused; rejected, with the reason). Accepted items are
folded into the plan body; the section stays as the audit trail and is
presented to the user with the plan.
For a pull request review, every Blocking and Should-fix item is one
pasteable comment (in the tiers of the repo's PR review rules, when it has
them): rationale, the anchor line `Replace \`path:N-M\`:` (repo-relative path,
exactly the lines the block replaces at the reviewed head), then the
```suggestion block at column 0 with the complete replacement. Print the
anchored lines (`git show <head>:<path> | sed -n 'N,Mp'`) before writing each
block, apply the blocks to a scratch copy of the head and build or run what
they touch, then run `scripts/check-docket.sh <docket.md> <head>`: it prints
anchored and replacement lines side by side and fails on a missing or
out-of-range anchor, an empty block, or a block indented as a markdown list
item (the paste would carry the indent). The docket goes into the chat, not
only into a file.

## After the panel (on the user's go)

- Fix round: implement the accepted items with gates and falsifiers per house
  rules. The held-out check is what proves the fixes, not another review: the
  test suites, the build and the first pipeline run catch what a reviewer
  reading the same diff again cannot. Scope any re-review to the fixes
  (`prepare-scope.sh <previously-reviewed-tree> HEAD`) so the finder reads the
  new lines rather than re-drawing findings against code the author has
  already accepted once.
  **The fix round is reviewed, not assumed.** When the fix commits touch a
  gate, a prompt, a cache-version constant, a pipeline stage or a runbook,
  that scoped re-review is required before the push, not offered. Those
  commits are written after the panel and are otherwise the only unreviewed
  code in the change. The diff is small, so this is one cheap Codex run and
  one judge turn.
  **The fix closes the class, not the site.** Apply each accepted item at
  every site the step 7 sweep named. Record the sweep in the item: the sites
  found, the sites fixed, and the reason for every site left alone. A site
  left alone with a reason is a decision. A site left alone in silence is the
  next reviewer's fresh should-fix.
- Findings the user declines: answer them in the pull request thread, with
  the reason. That reply is the whole record, and the next reviewer reads the
  threads, not this chat.
- Decisions for the user that stay unresolved go into the PR description, one
  bullet each.
- Emit the artifact:

  ```bash
  printf '{"tree":"%s","verdict":"reviewed","date":"%s","findings":%d,"survivors":%d}\n' \
    "$(git rev-parse 'HEAD^{tree}')" "$(date +%F)" <total> <survivors> \
    > .claude/.last-review.json
  ```

  Any later commit invalidates it (tree-bound); re-emit after the tree
  changes. In uncommitted mode `HEAD^{tree}` is the base tree, not the
  reviewed work: write `{"verdict":"deferred"}` and re-emit with the real
  tree hash once the work is committed.
- The panel is a pre-filter, never the last arbiter. The held-out check (the
  test suites, an evaluation run for a prompt change, the first pipeline run)
  decides whether the thing works; a green panel proves review coverage, not
  behavior.

## Head library (deep mode)

`heads/_focus.md` is the default review focus (the delivery, dependency,
identity, conformance and situate stances in one Codex review; the absence
class enters default mode only through the scope exception, so parity
coverage needs deep). `heads/*.md` are the stance heads for deep mode,
rendered behind `heads/_preamble.md` by `run-heads.sh`: attack `delivery`,
`dependency`, `identity` (identity, redaction and gates), `reach` (who can
start the code and what it holds while it runs), `falsify` (for each check,
the mutation it still passes); absence `parity` (names the sibling that sets
the precedent); situate `situate` (names its source); conform `conform`
(cites its authority, no failure scenario); library-only `daytwo` (rotation,
re-run, purge), `invariants` (the project invariants of the profile context
and the couplings around them) and `ux` (the page, the PDF and the deck
against the story's design boards: missing states, copy that differs in
meaning, numbers and legends shown differently, controls a keyboard or
screen-reader user cannot reach). The deep default is delivery, dependency,
identity, parity, situate, reach, falsify (`deepHeads` changes it); conform,
daytwo, invariants and ux are selected explicitly: conform in every plan
review, where there is no code to compare against a sibling; daytwo when the
diff carries rotation, re-run or purge procedures; invariants when the change
touches an invariant the profile context names; ux when the story attaches a
design and the diff renders it, after the orchestrator unpacks the boards into
the scratchpad and lists their paths in `facts.md` under "UI reference
material" (a head reads no zip, so the unpacking happens before the run).
A profile head file `heads/<head>.md` is appended to the generic head of that
name as project detail (the sibling folders to read, the store that counts as
durable), or is a head of its own when the plugin has none.
A new head is admitted only when external review or an escaped defect shows
a class no existing stance covers. `ux` was admitted that way: in three
panels on one story it raised three design departures that no attack or
absence head raised.
Edit the prompt file, never the rendered copy in the scope dir. The
preamble behind every head separates reading from reporting: a head reads
anywhere in the repo and reports only against the scope file list.

## Held-out checks of the harness

`${CLAUDE_PLUGIN_ROOT}/tests/review-panel-matrix.sh` exercises the guards
against fixture repos, with fake `codex` and `grok` binaries. The guards that
must keep working: `prepare-scope.sh` creating a scope for branch, uncommitted
and plan subjects; `check_scope_integrity` refusing a missing manifest, a
tampered diff, a drifted checkout, dirty scoped files and a working tree that
changed after an uncommitted scope was prepared; `run-adversarial.sh`
refusing a plan scope, an unpinned codex or companion version and a
mismatching engine target; the `HARNESS_CHANGED` flag; the profile loader
refusing an unknown key and a bad `prHost`; and `check-docket.sh` accepting an
exact anchor while refusing an out-of-range anchor, a block without an anchor
line and a list-indented block. A change to a guard is proven by a case that
fails without it.

## Cost and caps

Default: one Codex review plus one judge turn. Deep: the stance heads plus
one judge turn. The marginal cost of a head is judge attention, not Codex
tokens. Admit heads by the class rule in the head library, never by count.
Do not add rounds beyond the fix-round cap; do not enable the codex plugin's
Stop-hook gate (documented usage-drain warning). `/code-review` is not part
of this panel: it fans out ten finder agents on the session model; run it
only when the user asks, and then at `low`.
