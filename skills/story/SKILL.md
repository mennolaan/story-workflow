---
name: story
description: Run one board story as its orchestrator. This session talks to the user and does every outward action. Handoff sessions plan, implement and review, report back by status token, and never ask the user. Every session saves its state at its save point (checkpointPercent of the model window, 350k tokens for a 1M model) and compacts at the next turn boundary.
argument-hint: <work item id>
disable-model-invocation: true
---

# Story orchestrator

This session is the **orchestrator** of one story. It asks the user every question and runs every outward action. It does not plan, implement or judge reviews. It reads digests, not diffs. That keeps its context small.

## Roles

| Role | Started by | Worktree, base | Owns (single writer) | Asks the user |
|---|---|---|---|---|
| orchestrator | the user, `/story <id>` | its own | the ledger; board, push, PR, cloud | yes, the only one |
| plan | orchestrator, `fresh` | own, detached at `origin/{{BASE}}` | `<slug>.md` | no |
| requirements/architect reviewer | orchestrator, optional Agent call | reads a bounded planning snapshot | returns findings only; no shared writes | no |
| implement | orchestrator, `fresh`, after PLAN READY | own, `{{BRANCH}}` | code, local commits, `## Implementation status` | no |
| implement, story branch | orchestrator, `fresh`, at the plan gate in parallel mode | own, `{{BRANCH}}` | the foundation and integrate tasks, every shared file, the merge, `## Implementation status` | no |
| implement, track | orchestrator, `fresh`, at the plan gate in parallel mode | own, `{{TRACK_BRANCH}}` from `{{BASE_SHA}}` | the tasks of its track, local commits, `<slug>.d/status-<track>.md` | no |
| pr-review | orchestrator, `fresh`, after the PR opens | own, detached at the PR head | `<slug>.d/pr-review-docket.md` | no |

The orchestrator selects a model and effort for each handoff using "Model routing
and session size" below. Never inherit the orchestrator's model by omission.
Handoffs use the orchestrator's permission mode. A session in another permission
mode holds incoming messages for approval.

## Files

All sessions of a story share the `.plans/` folder of the main checkout: `$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.plans`. Every worktree reaches it by absolute path. It is gitignored.

- `<slug>.md`: the plan, its `## Review`, then `## Implementation status`.
- `<slug>.d/ledger.md`: the orchestrator ledger (template: `ledger.md` beside this file).
- `<slug>.d/routing.json`: task profiles, context estimates and reasons, proposed by the planner and finalized by the orchestrator.
- `<slug>.d/acceptance.json`: approved criteria and verification scenarios, frozen by the orchestrator before implementation (`review.md`).
- `<slug>.d/planning-reviews/`: orchestrator-owned specialist input snapshots and reports (`planning-review.md`); the planner records dispositions in the plan.
- `<slug>.d/reviews/<scope>/`: captured check logs, findings, judge decisions and review events. Protected receipts/contract live under `.sessions/review-<slug>/`.
- `<slug>.d/<role>.md`: the checkpoint of each role (`/checkpoint`). A track session writes `<slug>.d/implement-<track>.md`.
- `<slug>.d/status-<track>.md`: the implementation status of one track. Only its track session writes it.
- `<slug>.d/compact/`: each compaction summary, the state copies and `log.tsv`.
- `.sessions/<key>.json`: the binding of one session. `story-bind.sh` in `${CLAUDE_PLUGIN_ROOT}/hooks/` writes it.
- `<slug>.d/pr-review-docket.md`: the pr-review docket, apart from the pr-review checkpoint, because `/checkpoint` rewrites its file.

The key is `CLAUDE_CODE_HOST_SESSION_ID`, and every process that a session's shell starts inherits it. So a `claude -p` started from the Bash tool of a bound session acts as that session: the role guard, the context guard and the compaction logs all use the parent's binding (live check E2, 2026-10-27). Start such a run without the key:

```bash
env -u CLAUDE_CODE_HOST_SESSION_ID claude -p "<prompt>"
```

## Start

0. Check the repo. Do nothing else until this passes.
   - Run `"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --check`. When it exits 1, stop. Show its message to the user and end the turn. The message names `.claude/story.json` and `story.example.json`.
   - Read the config file that it prints. It fills the placeholders below.
   - Run `claude --version` and show the version. The context-keeper mod needs 2.1.308 or later. Below that, or when `claude` is not on PATH, say that the mod may not run and the backstop compacts instead.
1. Bind this session: `"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" orchestrator <slug>`. The slug is `<id>-<short-name>`. When it refuses because the backstop is off, stop and show the user its message.
2. Read the story and its tasks with the story-reader agent (Agent, `subagent_type: "story-workflow:story-reader"`, `model: "haiku"`, `effort: "low"`). Its prompt holds `{{BOARD_SHOW}}` and asks for each child task. Use its digest.
3. Write `<slug>.d/ledger.md` from the template. Set the session title.
4. Read `planning-review.md`. Decide whether requirements review is useful now and whether architecture review should wait for the draft. Record run/skip/defer reasons in the ledger. Fetch missing facts through the cheap readers first. Resolve genuine scope questions from existing authority or the user. If selected now, run the requirements reviewer with explicit resolved model/effort and retain its findings for the planner.
5. Start the plan session with `briefs/plan.md`, filled in, plus any intake specialist report and scope decisions.

## Starting a handoff session

- Run `"${CLAUDE_PLUGIN_ROOT}/hooks/story-route.sh" <role> [<routing.json> <task,task,...>]` first. Use its `model` and `effort` explicitly in `start_session`, with `context: "fresh"` and its own worktree. Use the live tool schema for the effort parameter; a sentence in the brief does not set it. If the host cannot set a value, report the mismatch and resolve it before starting work. Never silently fall back to Opus.
- Verify the model and effort from the created session's configuration/usage tools when exposed. Record requested and observed settings in the ledger; otherwise record `unverified`. Recheck on resume, `/clear`, fallback or escalation. The resolver checks its shell environment only: inspect the effective Desktop environment and managed settings too.
- The brief is the matching file in `briefs/`, with every `{{...}}` filled in. The orchestrator id is `$CLAUDE_CODE_HOST_SESSION_ID` in this session.
- Record the child (name, id, role, state) in the ledger at once. Then run `"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --adopt <child id>`. The guard resets only an adopted child with `clear_session` and no prompt.
- **Unpushed branch.** `start_session` with `source_branch` cuts the worktree from `origin/<branch>` when that remote ref exists (live check, 2026-10-27). Before you start a session from a feature branch with unpushed commits, give a local-only branch (no remote ref) as `source_branch`, or push first after the user's go.
- **Live checks of `.claude/` changes.** A worktree session that the desktop app starts reads settings, hooks, skills, agents, commands and `.mcp.json` from the main checkout root. Its hooks run there and `$CLAUDE_PROJECT_DIR` points there. `CLAUDE.md` and `.claude/rules/` still load from the worktree. Source: code.claude.com/docs/en/worktrees, "What worktrees share with the main checkout" (as of 2026-10-27, confirmed live). So a story that changes `.claude/` settings, hooks or skills runs its live checks in a plain checkout (a temporary clone), never in a desktop worktree session. When the main checkout path holds a space, the clone path holds one too, for example `~/Repo/<repo> <id> livecheck`. On 2026-10-27 a live check passed in a clone with no space and missed two Blocking path defects in the mod.

| Placeholder | Value |
|---|---|
| `{{STORY_ID}}`, `{{STORY_TITLE}}`, `{{TASKS}}` | the work item id and title; each task as `#<id> <title>` |
| `{{SHORT_TITLE}}`, `{{SLUG}}` | a few words for the session title; `<id>-<short-name>` |
| `{{PLANS}}` | the absolute path of the shared `.plans/` folder |
| `{{PLUGIN}}` | `${CLAUDE_PLUGIN_ROOT}`, the root folder of this plugin |
| `{{ORCHESTRATOR_ID}}` | `$CLAUDE_CODE_HOST_SESSION_ID` of this session |
| `{{EXECUTION_POLICY}}` | the route's model, effort, reason, estimated context/target, sizing warnings, owned tasks, escalation trigger, and "prefer independent parallel handoffs; checkpoint and compact when needed" |
| `{{BASE}}` | `baseBranch` of the config, for example `development` |
| `{{BRANCH}}` | `branch` of the config, with `{id}` the work item id and `{slug}` the short name |
| `{{BOARD_SHOW}}` | `board.show` of the config, with `{id}` filled in. Only the story-reader agent runs it. |
| `{{PR_CREATE}}` | orchestrator only: `pr.create` of the config, with `{branch}`, `{base}`, `{ids}`, `{title}` and `{description}` filled in |
| `{{REVIEW_PLAN}}` | `review.plan` of the config, with `{plan}` the absolute plan path |
| `{{REVIEW_CHANGES}}`, `{{REVIEW_PR}}` | `review.changes` and `review.pr` of the config |
| `{{REVIEW_BASE_SHA}}` | the immutable original base commit for foundation/integrated review, read before implementation starts; for a track use `{{BASE_SHA}}` |
| `{{REVIEW_FALLBACK}}` | `review.fallback` of the config: the command to run when the review command stops because a tool it needs is missing |
| `{{CONVENTIONS}}` | `conventions` of the config: the file that holds the conventions and checks of the repo. Default `CLAUDE.md` |
| `{{STORY_NOTES}}` | how to read the story: the story-reader agent (Agent, `subagent_type: "story-workflow:story-reader"`, `model: "haiku"`, `effort: "low"`) with `{{BOARD_SHOW}}` in its prompt, plus what the user said about scope |
| `{{SCOPE}}` | the plan's order of work that this session owns, and what it must not do yet |
| `{{PR_URL}}`, `{{BOARD_PATHS}}` | the PR link; the design board paths, or "none" |
| `{{PHASES}}` | implement only: one numbered line per phase, from the plan's order of work, as `<n>. #<task id> <title>. Done when: <check>.` One board task per line. The last line is the review phase, which ends with `DOCKET`. In parallel mode ("Parallel tracks"): for the story-branch session the foundation tasks, `#{{STORY_ID}} Merge the tracks`, the integrate tasks and the review; for a track the tasks of the track, and the last one ends with `DONE {{TRACK_BRANCH}} <sha>`. |
| `{{TRACK}}` | track only: the track name that `story-groups.sh` prints, for example `A`, `A+B` or `t2` |
| `{{TRACK_BRANCH}}` | track only: `{{BRANCH}}-{{TRACK}}`, a local branch that is never pushed |
| `{{TRACK_TASKS}}` | track only: the task ids of the track, comma separated, as `story-groups.sh --scope` takes them, for example `430,431` |
| `{{BASE_SHA}}` | track only: the commit the track branch starts from. With foundation tasks: `pending` until `## Tracks` holds the base sha, then that sha. While it is `pending`, the sha comes with the first `next:`. Without: the head of `origin/{{BRANCH}}` when it exists, else of `origin/{{BASE}}`, read at the plan gate |
| `{{PLAN_TASK}}`, `{{REVIEW_TASK}}` | the board task of the plan phases and of the PR review phases; the story id when the board has no such task |

`story.example.json` beside this file is a GitHub example without a `review` block. To run a review panel, add `"review": {"plan": ..., "changes": ..., "pr": ..., "fallback": ...}` with the review commands of the repo. A key that the config does not have fills its placeholder with `none`. Without a `review` block every `{{REVIEW_*}}` is `none`: the sessions skip the panel and say so in their report, and the orchestrator tells the user at the plan gate and at the docket step. Conventions (commits, prose, verification, research, PR review) come from the repo's `{{CONVENTIONS}}`, never from this plugin.

## Flow

1. **Plan.** The plan session writes the draft and ends its Draft phase with `PHASE DONE`. Before advancing it, reassess both optional specialists using `planning-review.md`; choose run/skip and explicit model/effort for each. Run independent selected reviews in parallel on one snapshot, relay findings to the planner and settle real scope/design decisions. The planner reconciles findings, then runs `{{REVIEW_PLAN}}` on the final proposal, folds in accepted findings and ends with `PLAN READY <path>`.
2. **Plan gate.** Read the plan summary, its `## Review` and `## Planning specialist review`. Match run/skip decisions and report snapshots to the ledger; resolve incomplete required reviews and blocking findings before freezing acceptance (`planning-review.md`). Run `"${CLAUDE_PLUGIN_ROOT}/hooks/story-groups.sh" "<plan path>"` on the plan's claims table. Its output is the authority, not the plan text. When it exits 1, send its message to the plan session to fix the table, and wait for `PLAN READY` again. Run `"${CLAUDE_PLUGIN_ROOT}/hooks/story-route.sh" --check "<plan path>" "<routing.json>"`. It checks exact manifest coverage and budgets every safe group and the story-branch scope (the entire story in sequential mode). On invalid input or conflicting settings send the reason back and start nothing. Sizing warnings are advisory: prefer more independent handoffs when they reduce elapsed time and total tokens; otherwise record why the scope stays together and allow checkpoint/compaction. If the user chooses sequential mode after a parallel proposal, rerun `story-route.sh implement <manifest> <all ids including merge,review>` to assess its combined size. Review the planner's profiles and reasons, especially requests for Opus or high effort. Read `review.md`, check each acceptance criterion and its verification scenario, and incorporate any scope decisions. After those decisions are settled, run `story-review.sh freeze <slug> <acceptance.json>` as orchestrator immediately before implementation starts. The freeze verifies safe-group membership and exact task coverage. Record the contract hash in the ledger. With `MODE sequential`, continue at once, with a short plan digest to the user, unless the plan lists an open decision for the user. Then show the digest and ask for that decision only. With `MODE parallel`, ask the user once ("Parallel tracks"), with the open decisions of the plan in the same turn.
3. **Implement.** Stop the plan session. In sequential mode, start the implement session with `briefs/implement.md`. It implements one phase per turn ("Phased turns and steering"), runs the verification of the repo's CLAUDE.md, commits locally, runs `{{REVIEW_CHANGES}}` and ends with `DOCKET <path>`. In parallel mode, start the story-branch session and the tracks ("Parallel tracks"). The story-branch session merges the tracks, runs the integrate tasks and the review, and ends with `DOCKET <path>`.
4. **Docket.** Send the findings that the judge accepted with evidence back for fixing. Ask the user only about design challenges and residual follow-ups. The implement session fixes and ends with `READY TO PUSH <branch> <sha>`.
5. **Push.** Ask the user one question: push and open the draft PR. On yes, push and run `{{PR_CREATE}}` here. When the config has no `pr.create`, ask the user how to open the PR. Set the title to 🔀 `PR OPEN`. Then start the pr-review session with `briefs/pr-review.md`.
6. **Close.** Unbind each child (`"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --unbind <child id>`), then this session (`story-bind.sh --unbind`). A binding outlives `/clear`, because its key is the host id, so a session reused after the story keeps its role until it is unbound. Report the result and the next steps. Set the title to `✅ <title>`.

## Model routing and session size

The orchestrator chooses the cheapest profile adequate for the work, considering
ambiguity, risk, verification and expected retries. The planner proposes task
profiles in `<slug>.d/routing.json` (`briefs/plan.md`). The resolver validates the
manifest and repo overrides and emits launch settings. It does not launch or
reconfigure sessions: applying and checking its output is the orchestrator's job.

| Work | Default | Escalate when |
|---|---|---|
| Planning, unresolved architecture, conflicting requirements | Opus/high | a bounded hard problem needs deeper reasoning; give evidence before xhigh/max |
| Optional requirements/acceptance review | Sonnet/medium | a bounded independent check; orchestrator selects profile/effort (`planning-review.md`) |
| Optional architecture review within established patterns | Sonnet/high | check contracts and independence; escalate unresolved design deliberately |
| Clearly specified implementation and test writing | Sonnet/medium | reproducible reasoning failure or newly discovered ambiguity |
| Review and judging findings | Sonnet/high | security, concurrency or cross-system reasoning warrants Opus/high |
| Fetch/extract wiki, Confluence, docs or board facts | Haiku/low | extraction is incomplete; synthesis returns to the planner |
| Execute prescribed checks and extract failures | Haiku/low | diagnosis or test design is required; return it to the implementer |

For plan and PR review, `story-route.sh plan` / `story-route.sh pr-review` resolve
role defaults; include manifest task ids when scope estimates are available.
Implementation must pass the manifest and the exact owned ids. Include `merge`
and `review` for the story branch; those rows ensure its final review is routed
at least Sonnet/high. A track selects the strongest model and effort of its
tasks. Avoid bundling a Haiku task into an Opus handoff when a short subagent can
return evidence instead. No default uses xhigh/max.

Use `story-workflow:source-reader` for named wiki/docs retrieval and
`story-workflow:test-runner` for exact check commands, with explicit Agent
model/effort from the resolved route (defaults: `model: "haiku"`, `effort: "low"`;
use the family alias when the Agent schema requires it). Board reads always use
`story-workflow:story-reader` with `model: "haiku"`, `effort: "low"`; the existing
board gate keeps that agent on Haiku even when other profiles are overridden. Resolve `reader` / `verification` first
to catch environment overrides. These narrow subagents return bounded evidence,
not decisions. Run local checks directly when delegation would add more work;
spawning a model does not make a deterministic test command run faster. Do not
delegate source writes to a test runner. Use Sonnet for test design or routine
failure diagnosis; Opus requires a specific hard reasoning problem.

The default handoff context target is 200k, including an estimated 100k startup.
`routing.startupTokens` and `routing.targetSessionTokens` are repo settings. Measure
actual startup and reduce it by trimming instructions, MCP payloads and brief
content. `story-route.sh` sets the advisory target no higher than the model's
checkpoint or 85% of the configured backstop. It sums task input/work estimates
once per session and reports `sizing`, `compactionLikely` and `warnings`. These
estimates guide planning; they are not a launch cap, live context meter or spend
limit. A large estimate warns without blocking the handoff.

Prefer more small, independent sessions running in parallel over a few long
sessions that repeatedly checkpoint and compact. Compare total elapsed time and
tokens, including startup, duplicated context, handoff/merge overhead, compaction
and rereading saved state. Split along real contracts and file ownership; do not
invent independence to meet the target. Keep tightly coupled work together when
splitting would add more overhead or serialize the same dependency chain.

At phase boundaries, use actual context and remaining work to reassess the scope.
Move genuinely independent, unstarted work to another handoff when useful; never
create two writers for the same owned files. Continue the current session when
it is the more efficient choice, using the existing checkpoint/compaction rules
when needed. Crossing the planning target alone does not require `QUESTION`, a
fresh successor or a pause. Ask the orchestrator about scope/ownership changes or
capability failures, not merely about needing compaction. Record compactions and
review repeated cycles as opportunities to improve future decomposition; a
necessary compaction is not itself a failed handoff.

Escalation uses `QUESTION` with failing evidence, attempts, remaining scope and
the requested profile. Resolve missing tools, credentials and rate limits as
operational blocks. For a capability failure, the orchestrator may raise effort
one step or route the remaining work to the next model, record why, and verify
the effective setting. Do not restart completed phases. No automatic retry loops.

## Parallel tracks

After the plan gate, independent tasks can run in one implement session each. The story keeps one branch and one PR. The repo turns it on with `parallel.max` of the config (default 1, off; the example opts in to 10). Prefer many bounded independent tracks over a few long sessions. The cap is a ceiling, not a target: dependencies, shared files, local CPU/test resources and usage limits determine useful concurrency. `parallel.shared` lists globs of shared or generated files, for example lockfiles.

### Waves

The plan puts each task in one wave, in a claims table under `## Order of work` (`briefs/plan.md`).

| Wave | Runs in | Branch | Holds |
|---|---|---|---|
| F (foundation) | the story-branch session, first | `{{BRANCH}}` | what every track needs: a frozen contract, the schema, a decision entry, a lockfile change |
| T (track) | one track session per track, at the same time | `{{TRACK_BRANCH}}`, cut from `{{BASE_SHA}}` | independent work |
| I (integrate) | the story-branch session, after the merge | `{{BRANCH}}` | shared and generated files, tasks that need two or more tracks |

`hooks/story-groups.sh` of this plugin applies the independence test. Two T tasks share a track when one depends on the other, when their claims touch one file (the same path, or a folder that holds the other path), or when the plan gives them one track label. Two claims `path#a` and `path#b` with different region names do not touch. A T task that claims a shared file moves to wave I, and so does each T task that depends on it. Exit 0: the plan's waves and labels hold. Exit 2: the test moved a task (`MOVE`) or merged two labelled tracks (`REFUSE`), and the output is the safe grouping. Exit 1: a bad table. The header of the script lists every rule and output line.

### The gate question

With `MODE parallel`, show the user:
- the groups: the foundation tasks, each track with its tasks and hours, the integrate tasks;
- every `JOIN`, `REFUSE` and `MOVE` line with its reason;
- the cap and the queue, as the `MODE` line prints them;
- each track's model, effort, rationale and estimated context/target and sizing warnings from the resolver; startup cost comes from configuration/measurement, not a fixed Claude Code constant.

Then ask: "Start N tracks in parallel, or one session?". When the plan lists an open decision for the user, ask it in the same turn, and start nothing before the user has answered all of them. Record each answer in the user's words in the ledger. On "one session", run the sequential flow.

### Start

Every start happens in the turn of the user's answer. The app refuses `start_session` on a turn that a message or an automated event started.
1. Start the story-branch session with `briefs/implement.md`. With foundation tasks, its phases start with them, and its last foundation phase ends with `PHASE DONE #<task> <sha>`. That sha is `{{BASE_SHA}}`. Without foundation tasks, its first turn only binds, reads the plan and switches to `{{BRANCH}}`, and ends with `PHASE DONE #{{STORY_ID}} -`.
2. Start the tracks, at most `parallel.max`, in table order, each with `briefs/implement-track.md` and its own worktree. Fill `{{TRACK}}` with the track name that `story-groups.sh` prints. Adopt each one. Record each in `## Tracks` of the ledger.
3. While `{{BASE_SHA}}` is `pending`, each track's first turn only binds and reads the plan, and ends with `PHASE DONE #<first task> -`. Else `{{BASE_SHA}}` is in the brief and the track starts its first task at once.
4. A track works on `{{TRACK_BRANCH}}` only. It never touches `{{BRANCH}}` and never pushes.

### The scheduler step

At each side-sessions event, for each child that ended a turn:
- Track `PHASE DONE #<task> -`: the track has bound and waits for its base. Check its binding and title only. Record it as `waits for base` in `## Tracks`, and send nothing. When `## Tracks` already holds the base sha, send `next: #<first task> base <sha>` at once.
- Story-branch `PHASE DONE #{{STORY_ID}} -`: it has bound and waits for the merge. Record it, and send nothing.
- Story-branch `PHASE DONE #<last foundation task> <sha>`: the phase check, plus the `foundation` evidence/review gate of `review.md` in its worktree. Release no dependent track before that gate returns `REVIEW OK`. Record the sha as the base sha in `## Tracks`. Send each waiting track `next: #<first task> base <sha>`.
- Track `PHASE DONE #<task> <sha>`: the phase check, plus `"${CLAUDE_PLUGIN_ROOT}/hooks/story-groups.sh" --scope "<plan path>" <track tasks> <base sha> <sha>` in the track's worktree. It must print `SCOPE ok`. A failed check is a deviation: send it back to the track, and ask the user only when the fix needs a plan change. Then send `next: #<next task>`.
- Track `DONE <track branch> <sha>`: the same checks, plus `story-review.sh gate <slug> track-<name> <all assigned task ids> <base sha>` in that track's worktree. Accept only `REVIEW OK` or an approved `CHECKS ONLY`, and save the receipt. On failure keep the implementer available for fixes and leave other tracks running. On success record the sha, unbind the track and stop it.
- Every other story-branch `PHASE DONE #<task> <sha>` (a foundation task that is not the last one, the merge, an integrate task), and `QUESTION`, `BLOCKED`, `CHECKPOINT`: as in "Status tokens".

For a `BLOCKED` report with `REVIEW QUEUED`, keep that track in `review queue` and send `next: review` when a finder slot is free; do not rerun its implementation phases. Other tracks continue. A `REVIEW LIMIT` or `CHECK LIMIT` report goes to the orchestrator with exact evidence: resolve the cause or a real decision, never retry in a loop.

Start queued tracks while fewer than `parallel.max` run. When the app refuses a start, keep the proposal card that the refusal offers. Record the track as `waits for the user` in the ledger, tell the user in one line which card to click, and set ❗. When every track is `DONE`, send the story-branch session `next: #{{STORY_ID}} merge`.

The app wakes the orchestrator when every running child is idle, so the tracks move in rounds, one phase each. Balance the labels: a short phase waits for the longest phase of its round.
Prefer a single bounded deliverable per track so most tracks finish in one work
turn. This reduces the round barrier; routing alone cannot remove the host's
wake-up and session-start restrictions. Use individual idle notifications when
the live host supports them, while keeping every scope and phase check.

### The merge

The story-branch session cherry-picks each track, in ledger order, onto `{{BRANCH}}` (`briefs/implement.md`, "Parallel mode"). The history stays linear, and each task commit keeps its message. A conflict means a claim was wrong: the session aborts the cherry-pick and ends with `BLOCKED`, and the orchestrator decides. Then the integrate tasks run as phases. Capture fresh whole-story evidence and run/gate the `integrated` scope with `all` (`review.md`), followed by any extra review the repo explicitly configures. Tracks run one focused finder by default, not the full repo panel. The track branches stay local.

### Turn it off

- For one story: the user answers "one session" at the gate.
- For the repo: `"parallel": {"max": 1}` in the config, or no `parallel` key.

## Acceptance and review gates

Read `review.md` for the executable evidence/review procedure. It uses the Codex
CLI directly and works without installing a separate review plugin. Python 3 and
an authenticated Codex CLI are required for this path. `handoffReview` sets the
finder model/effort, concurrency, timeout and round/check-failure limits. These
are separate from Claude handoff routing and the implementation concurrency cap.

Review shared foundation before releasing dependent tracks; review each completed
substantive handoff while other tracks keep working; review the integrated story
against every criterion and its runtime wiring. Preserve the implementing session
until its review gate is accepted so fixes do not require reconstructing context.
A checkpoint or a small phase report does not itself trigger another finder.
Approved trivial tracks may use `checksOnly` with captured evidence and a reason.

The orchestrator does not judge raw findings. It checks the machine-readable
receipt in the owned worktree before accepting `DONE`, and before the docket/push
step for the `integrated` scope. The implementation session validates findings,
fixes accepted defects and records supported false-positive dismissals. A changed
revision, base, contract or check record invalidates prior approval. Configured
additional panels retain their repo policy and are not silently substituted.

## Status tokens (child to orchestrator)

The first line of a child's `wrap_up` recap is one token. The side-sessions event shows the first 400 characters. The full text is in the child's state file or in a `SendMessage`.

| Token | The orchestrator does |
|---|---|
| `PHASE DONE #<task> <sha>` | the phase check, then `next: #<task>` ("Phased turns and steering"); at the plan Draft boundary first resolve optional specialist selection/reviews using `planning-review.md` |
| `PLAN READY <path>` | the plan gate |
| `QUESTION` | answers from the plan, the repo's `{{CONVENTIONS}}`, the wiki, memory and the user's earlier answers. Escalates to the user only what none of those settle. |
| `DOCKET <path>` | the docket step |
| `READY FOR LIVE CHECKS <branch> <sha>` | runs the live checks of the plan, then relays the results |
| `READY TO PUSH <branch> <sha>` | the push step |
| `BLOCKED` | reads the reason, removes the block or asks the user |
| `CHECKPOINT` | nothing while the child's context drops (`get_usage`). If it stays high (no mod), `clear_session` the child and send `Continue from <state path>`. |
| `DONE` | records it, unbinds the child (`story-bind.sh --unbind <child id>`), stops the session. A track sends `DONE <track branch> <sha>`: the phase/scope checks and its acceptance/review gate first, then record the sha in `## Tracks`. Do not archive a track before the story PR is open: its branch is the only copy of its work. |

When you relay an approval, quote the user's words.

## Session title states

The session title shows the state: one emoji, then `<Role> · <story id> <short name>`. The roles are `Orchestrator`, `Plan`, `Implement` and `PR review`. Set the title with `set_session_title` (session `self`) as the last step before `wrap_up`. Remove the emoji while the session works. This table is the one map. The briefs, `/checkpoint` and the repo's CLAUDE.md follow it, and the hook matrix of this plugin checks the briefs and `/checkpoint`.

| Emoji | Token | State | Who |
|---|---|---|---|
| ❗ | - | waits on the user: a decision, an approval, a go | orchestrator |
| ⛔ | - | blocked on a fix only the user can make | orchestrator |
| 📋 | `PLAN READY` | plan ready and reviewed | plan |
| 💬 | `QUESTION` | question sent to the orchestrator | handoff |
| 🔍 | `DOCKET` | review docket ready | implement, pr-review |
| 🧪 | `READY FOR LIVE CHECKS` | built and checked, live checks next | implement |
| 📦 | `READY TO PUSH` | committed and reviewed | implement |
| 🚧 | `BLOCKED` | blocked, reported to the orchestrator | handoff |
| 🔀 | `PR OPEN` | pushed, draft PR open, waits on the review or the merge | orchestrator |
| 🧩 | `PHASE DONE` | one phase of the brief done and committed, waits on the next go | handoff |
| ⏳ | - | waits on other work: a session, Codex, CI, a pipeline | any |
| 💾 | `CHECKPOINT` | state saved, compaction pending | any |
| ✅ | `DONE` | done, nothing open | any |

- A handoff session never shows ❗ or ⛔. The orchestrator shows them for the user.
- The orchestrator removes its own ❗ or ⛔ with `set_session_title` at the start of the turn that the user's answer starts. No hook does it, because the desktop app ignores the title output of a hook (live check E0c, 2026-10-27). A cross-session message or a side-sessions event keeps the title.
- Advance the task list with `update_plan` at the start of each step. A long turn shows no chat text, so the list is what the user watches.

## Phased turns and steering

The context rule acts only at a turn boundary, and the orchestrator hears nothing until a child's turn ends. One long turn can pass the save point with no boundary, and the backstop then compacts in the middle of the work.

1. **One phase per turn.**
   - Each brief lists its phases in order, one board task each.
   - A child does one phase per turn and commits it. It updates its state section and sets its title to 🧩.
   - It ends the turn with `PHASE DONE #<task> <sha>`. `<sha>` is the short sha of the phase commit, or `-` when the phase commits nothing (plan, pr-review).
   - The last phase ends with the role's final token instead (`PLAN READY`, `READY FOR LIVE CHECKS`, `DOCKET`, `READY TO PUSH`).
2. **The orchestrator sends the next go itself.** It asks the user nothing for it.
   - On the side-sessions event, check four things: the status line, the commit (`git log -1 <sha>` in the child's worktree), the child's context (`get_usage`) and any new deviation in the child's state section.
   - At the plan Draft boundary, first resolve optional specialist run/skip decisions and any selected reviews (`planning-review.md`). Then send `next: #<task>` by the peer route (rule 3), including the reports and settled decisions.
   - Ask the user only when a deviation needs a decision that the plan does not settle.
   - When the child is at or above the save point (350k tokens for a 1M model) and its mod is not live, first ask it for `/checkpoint`. Then clear it (`clear_session`) and send `Continue from <state path>`.
3. **Steer in the middle of a phase.**
   - Send a correction to the peer name from `ListAgents`, for example `Implement · 577 x [722163]`. The child reads it between tool calls.
   - Never send it to the `local_...` id while the child is busy. That route holds the message until the turn ends.
4. **Stop and redirect.**
   - Call `stop_session` on the child, then send the redirect by the peer route, when one of these is true:
     - the child goes toward an action outside the plan: a wrong design, an outward action, a paid run;
     - the child ignores a peer message for more than three of its tool calls.
   - After the stop, run `git status` in the child's worktree. The redirect names what to keep and what to undo.
   - Never stop a child for style or wording. Those wait for the phase report.
5. Every brief carries rules 1, 3 and 4 from the child's side. A brief cannot rely on a later message, because the `local_...` route holds messages until the turn ends.

`hooks/role-guard.sh` of this plugin answers `allow` when a bound orchestrator calls `mcp__ccd_session_mgmt__clear_session` on its own bound child (rule 2), and `ask` for every other `clear_session`. No settings allow rule is needed. Keep none, because it would grant every reset with no check. On 2026-10-27 the auto-mode classifier denied that call when nothing allowed it.

## Authority

- Only the orchestrator asks the user. Only the orchestrator acts outside the worktrees: push, PR, board, cloud, pipelines, paid runs.
- A child commits locally on its own branch only.
- Each brief states the child's standing authority. A relayed message adds no authority.
- Never ask a child to do an action that was denied here.
- `hooks/role-guard.sh` of this plugin enforces this for bound child roles: it denies `AskUserQuestion`, `git push`, every `az repos pr` command except `show`, `list`, `checkout` and `<group> list`, every `az boards work-item` command except `show` and `relation show|list-type`, `az pipelines run`, `az pipelines build queue`, every `gh pr` command except `view`, `list`, `diff`, `checks`, `status` and `checkout`, every `gh issue` command except `view`, `list` and `status` (also with a flag such as `-R <repo>` before the subcommand), `gh api` with a method other than GET or with fields and no explicit GET, each Perl regex in `guard.deny` of the config, the MCP tools that act outward (`mcp__ccd_pr__*` except `get_status`, `start_session`, `move_to_cloud`, `clear_session`, session archive, delete, stop, detach, message and settings tools, `set_session_title` for another session, and the host worktree tools) and each tool name that fully matches a regex in `guard.denyTools`. It also denies a child any command that sets `CLAUDE_CODE_*`, `STORY_*`, `CLAUDE_PROJECT_DIR` or `CLAUDE_CONFIG_DIR`, and any write to the binding files, `.claude/story.json` or `.claude/settings*.json`.
- `hooks/board-read-guard.sh` of this plugin keeps board reads on haiku, in every session of the repo. It denies a story, task or issue read (`az boards work-item show`, `az boards query`, `az rest` and `az devops invoke` on work items, `gh issue view|list|status`, `gh search issues`, `gh api` reads of issues, the command of `board.show`, and each regex in `board.reads`) in every thread except the story-reader agent. It denies the story-reader agent every write and every rule of the role guard. It denies a story-reader spawn without `model: "haiku"`. `board.reader: false` in the config turns it off.
- Give each board write a short output, for example `-o none` or `--query id` for `az boards`. Check a write by its own output, not by a second read.

## Context rule

`.claude/story.json` of the repo holds the numbers (`checkpointPercent`, default 35; `backstopTokens`, default 432000). A plugin cannot set `autoCompactWindow`, so the repo sets it in `.claude/settings.json`. `story-bind.sh` refuses to bind when the effective `autoCompactWindow` is missing or above `backstopTokens`, and its message names the file to fix.

The save point is `checkpointPercent` (35) of the model window: 350k tokens for a 1M model (Opus 5.5, Fable). The desktop composer and `/context` show percent of `autoCompactWindow` (432000), so the save point shows as 81% there and the backstop compaction starts at 92%.

Steps 1, 2, 4, 5 and 7 run only on a context window of 400k tokens or more. The original setup measured startup near 100k tokens; at that size a 200K window cannot compact below the save point. Measure startup for the consuming repo rather than assuming this overhead for every session.

1. **Nudge.** `context-guard.sh` (PostToolUse) adds one note per crossing: run `/checkpoint` at the next safe moment.
2. **Gate.** The same script (Stop) blocks the end of the turn once while the checkpoint is stale.
3. **Save.** `/checkpoint` writes the state file and ends with `CHECKPOINT-READY: <path> | continue` (or `| wait`).
4. **Compact.** The context-keeper mod (`hooks/register.tsx` of this plugin) compacts at the turn boundary once the checkpoint is fresh. With a stale checkpoint it runs `/checkpoint` once, then shows a toast. A checkpoint is stale too when more than 3 main turns ended after its last write (a turn kept the compaction from running). Then the mod runs `/checkpoint` again, once, and compacts at a later turn end, after the new write.
5. **Steer.** The mod adds the role and the state path to the instructions of every compaction.
6. **Re-prime.** `session-reprime.sh` (SessionStart `startup|clear|compact`) prints the role card, the paths and the saved state of a bound session.
7. **Resume.** After a `continue` checkpoint the mod sends `Continue from <path>: next action <...>`, 3 seconds after the compaction ends. Not after `wait`, a turn that starts after the compaction (a background notice starts one), an aborted turn, a draft in the prompt box, a prompt from the person or the host, a checkpoint written after the compaction, or a checkpoint more than 3 turns behind when the compaction runs (a queued `/compact`; the mod logs it). A turn that started before the compaction ended and runs at that time moves the check to its end.
8. **Backstop.** Without the mod, auto-compaction runs at about 400k tokens (40% of a 1M window), with the state already saved by steps 1 to 3. Claude Code compacts about 32k tokens below `autoCompactWindow` (E0 on 2026-10-27: 92% of 400000, about 368k; the reserve is inferred from two data points), so `autoCompactWindow` and `backstopTokens` are 432000.

The orchestrator follows the same rule. Its checkpoint adds the linked sessions and the questions that wait on the user.
