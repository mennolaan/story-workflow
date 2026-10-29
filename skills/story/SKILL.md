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
| implement | orchestrator, `fresh`, after PLAN READY | own, `{{BRANCH}}` | code, local commits, `## Implementation status` | no |
| pr-review | orchestrator, `fresh`, after the PR opens | own, detached at the PR head | `<slug>.d/pr-review-docket.md` | no |

Handoff sessions run `claude-opus-5-5` at `high`, in the orchestrator's permission mode. A session in another permission mode holds incoming messages for approval.

## Files

All sessions of a story share the `.plans/` folder of the main checkout: `$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.plans`. Every worktree reaches it by absolute path. It is gitignored.

- `<slug>.md`: the plan, its `## Review`, then `## Implementation status`.
- `<slug>.d/ledger.md`: the orchestrator ledger (template: `ledger.md` beside this file).
- `<slug>.d/<role>.md`: the checkpoint of each role (`/checkpoint`).
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
2. Read the story and its tasks from the board with `{{BOARD_SHOW}}`.
3. Write `<slug>.d/ledger.md` from the template. Set the session title.
4. Ask scope questions only when the board leaves a real gap.
5. Start the plan session with `briefs/plan.md`, filled in.

## Starting a handoff session

- `start_session` with `context: "fresh"`, its own worktree, `model: "claude-opus-5-5"`, effort `high`.
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
| `{{BASE}}` | `baseBranch` of the config, for example `development` |
| `{{BRANCH}}` | `branch` of the config, with `{id}` the work item id and `{slug}` the short name |
| `{{BOARD_SHOW}}` | `board.show` of the config, with `{id}` filled in |
| `{{PR_CREATE}}` | orchestrator only: `pr.create` of the config, with `{branch}`, `{base}`, `{ids}`, `{title}` and `{description}` filled in |
| `{{REVIEW_PLAN}}` | `review.plan` of the config, with `{plan}` the absolute plan path |
| `{{REVIEW_CHANGES}}`, `{{REVIEW_PR}}` | `review.changes` and `review.pr` of the config |
| `{{REVIEW_FALLBACK}}` | `review.fallback` of the config: the command to run when the review command stops because a tool it needs is missing |
| `{{CONVENTIONS}}` | `conventions` of the config: the file that holds the conventions and checks of the repo. Default `CLAUDE.md` |
| `{{STORY_NOTES}}` | how to read the story (`{{BOARD_SHOW}}`), plus what the user said about scope |
| `{{SCOPE}}` | the plan's order of work that this session owns, and what it must not do yet |
| `{{PR_URL}}`, `{{BOARD_PATHS}}` | the PR link; the design board paths, or "none" |
| `{{PHASES}}` | implement only: one numbered line per phase, from the plan's order of work, as `<n>. #<task id> <title>. Done when: <check>.` One board task per line. The last line is the review phase, which ends with `DOCKET`. |
| `{{PLAN_TASK}}`, `{{REVIEW_TASK}}` | the board task of the plan phases and of the PR review phases; the story id when the board has no such task |

`story.example.json` beside this file is a GitHub example without a `review` block. To run a review panel, add `"review": {"plan": ..., "changes": ..., "pr": ..., "fallback": ...}` with the review commands of the repo. A key that the config does not have fills its placeholder with `none`. Without a `review` block every `{{REVIEW_*}}` is `none`: the sessions skip the panel and say so in their report, and the orchestrator tells the user at the plan gate and at the docket step. Conventions (commits, prose, verification, research, PR review) come from the repo's `{{CONVENTIONS}}`, never from this plugin.

## Flow

1. **Plan.** The plan session writes the plan, runs `{{REVIEW_PLAN}}` on the first full proposal, folds in the accepted findings and ends with `PLAN READY <path>`.
2. **Plan gate.** Read the plan summary and its `## Review`. Continue at once, with a short plan digest to the user, unless the plan lists an open decision for the user. Then show the digest and ask for that decision only.
3. **Implement.** Stop the plan session. Start the implement session with `briefs/implement.md`. It implements one phase per turn ("Phased turns and steering"), runs the verification of the repo's CLAUDE.md, commits locally, runs `{{REVIEW_CHANGES}}` and ends with `DOCKET <path>`.
4. **Docket.** Send the findings that the judge accepted with evidence back for fixing. Ask the user only about design challenges and residual follow-ups. The implement session fixes and ends with `READY TO PUSH <branch> <sha>`.
5. **Push.** Ask the user one question: push and open the draft PR. On yes, push and run `{{PR_CREATE}}` here. When the config has no `pr.create`, ask the user how to open the PR. Set the title to 🔀 `PR OPEN`. Then start the pr-review session with `briefs/pr-review.md`.
6. **Close.** Unbind each child (`"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --unbind <child id>`), then this session (`story-bind.sh --unbind`). A binding outlives `/clear`, because its key is the host id, so a session reused after the story keeps its role until it is unbound. Report the result and the next steps. Set the title to `✅ <title>`.

## Status tokens (child to orchestrator)

The first line of a child's `wrap_up` recap is one token. The side-sessions event shows the first 400 characters. The full text is in the child's state file or in a `SendMessage`.

| Token | The orchestrator does |
|---|---|
| `PHASE DONE #<task> <sha>` | the phase check, then `next: #<task>` ("Phased turns and steering") |
| `PLAN READY <path>` | the plan gate |
| `QUESTION` | answers from the plan, the repo's `{{CONVENTIONS}}`, the wiki, memory and the user's earlier answers. Escalates to the user only what none of those settle. |
| `DOCKET <path>` | the docket step |
| `READY FOR LIVE CHECKS <branch> <sha>` | runs the live checks of the plan, then relays the results |
| `READY TO PUSH <branch> <sha>` | the push step |
| `BLOCKED` | reads the reason, removes the block or asks the user |
| `CHECKPOINT` | nothing while the child's context drops (`get_usage`). If it stays high (no mod), `clear_session` the child and send `Continue from <state path>`. |
| `DONE` | records it, unbinds the child (`story-bind.sh --unbind <child id>`), stops the session |

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
   - Then send `next: #<task>` by the peer route (rule 3).
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

## Context rule

`.claude/story.json` of the repo holds the numbers (`checkpointPercent`, default 35; `backstopTokens`, default 432000). A plugin cannot set `autoCompactWindow`, so the repo sets it in `.claude/settings.json`. `story-bind.sh` refuses to bind when the effective `autoCompactWindow` is missing or above `backstopTokens`, and its message names the file to fix.

The save point is `checkpointPercent` (35) of the model window: 350k tokens for a 1M model (Opus 5.5, Fable). The desktop composer and `/context` show percent of `autoCompactWindow` (432000), so the save point shows as 81% there and the backstop compaction starts at 92%.

Steps 1, 2, 4, 5 and 7 run only on a context window of 400k tokens or more. A story session starts near 100k tokens, so on a 200K window no compaction gets below the save point.

1. **Nudge.** `context-guard.sh` (PostToolUse) adds one note per crossing: run `/checkpoint` at the next safe moment.
2. **Gate.** The same script (Stop) blocks the end of the turn once while the checkpoint is stale.
3. **Save.** `/checkpoint` writes the state file and ends with `CHECKPOINT-READY: <path> | continue` (or `| wait`).
4. **Compact.** The context-keeper mod (`hooks/register.tsx` of this plugin) compacts at the turn boundary once the checkpoint is fresh. With a stale checkpoint it runs `/checkpoint` once, then shows a toast.
5. **Steer.** The mod adds the role and the state path to the instructions of every compaction.
6. **Re-prime.** `session-reprime.sh` (SessionStart `startup|clear|compact`) prints the role card, the paths and the saved state of a bound session.
7. **Resume.** After a `continue` checkpoint the mod sends `Continue from <path>: next action <...>`. Not after `wait`, an aborted turn, a draft in the prompt box or a prompt from the person.
8. **Backstop.** Without the mod, auto-compaction runs at about 400k tokens (40% of a 1M window), with the state already saved by steps 1 to 3. Claude Code compacts about 32k tokens below `autoCompactWindow` (E0 on 2026-10-27: 92% of 400000, about 368k; the reserve is inferred from two data points), so `autoCompactWindow` and `backstopTokens` are 432000.

The orchestrator follows the same rule. Its checkpoint adds the linked sessions and the questions that wait on the user.
