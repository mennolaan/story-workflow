# Parallel tracks

Read by the orchestrator of `/story` (`SKILL.md` beside this file) when the plan gate prints `MODE parallel`, and again at each side-sessions event while tracks run.

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
- Story-branch `PHASE DONE #<last foundation task> <sha>`: the phase check, plus the `foundation` evidence/review gate of `review.md` in its worktree. Release no dependent track before that gate returns `REVIEW OK`. Record the sha as the base sha in `## Tracks`, and pin it for each track: `story-review.sh pin <slug> track-<name> <sha>`. Send each waiting track `next: #<first task> base <sha>`.
- Track `PHASE DONE #<task> <sha>`: the phase check, plus `"${CLAUDE_PLUGIN_ROOT}/hooks/story-groups.sh" --scope "<plan path>" <track tasks> <base sha> <sha>` in the track's worktree. It must print `SCOPE ok`. A failed check is a deviation: send it back to the track, and ask the user only when the fix needs a plan change. Then send `next: #<next task>`.
- Track `DONE <track branch> <sha>`: the same checks, plus `story-review.sh gate <slug> track-<name> <all assigned task ids> <base sha>` in that track's worktree. Accept only `REVIEW OK` or an approved `CHECKS ONLY`, and save the receipt. On failure keep the implementer available for fixes and leave other tracks running. On success record the sha, unbind the track and stop it.
- Every other story-branch `PHASE DONE #<task> <sha>` (a foundation task that is not the last one, the merge, an integrate task), and `QUESTION`, `BLOCKED`, `CHECKPOINT`: as in "Status tokens".

For a `BLOCKED` report with `REVIEW QUEUED`, keep that track in `review queue` and send `next: review` when a finder slot is free; do not rerun its implementation phases. Other tracks continue. A `REVIEW LIMIT` or `CHECK LIMIT` report goes to the orchestrator with exact evidence: resolve the cause or a real decision, never retry in a loop. When the fixes converge, `story-review.sh reset <slug> <scope> <reason>` opens new review rounds for that scope (`review.md`); record the reason in the ledger.

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
