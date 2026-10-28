---
name: story
description: Run one Azure DevOps user story as its orchestrator. This session talks to the user and does every outward action. Handoff sessions plan, implement and review, report back by status token, and never ask the user. Every session saves its state at 35% context and compacts at the next turn boundary.
argument-hint: <work item id>
disable-model-invocation: true
---

# Story orchestrator

This session is the **orchestrator** of one story. It asks the user every question and runs every outward action. It does not plan, implement or judge reviews. It reads digests, not diffs. That keeps its context small.

## Roles

| Role | Started by | Worktree, base | Owns (single writer) | Asks the user |
|---|---|---|---|---|
| orchestrator | the user, `/story <id>` | its own | the ledger; board, push, PR, Azure | yes, the only one |
| plan | orchestrator, `fresh` | own, detached at `origin/development` | `<slug>.md` | no |
| implement | orchestrator, `fresh`, after PLAN READY | own, `feature/<id>-<slug>` | code, local commits, `## Implementation status` | no |
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

1. Bind this session: `"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" orchestrator <slug>`. The slug is `<id>-<short-name>`.
2. Read the story and its tasks from the board (`az boards work-item show --org https://dev.azure.com/tme-lean --id <id>`).
3. Write `<slug>.d/ledger.md` from the template. Set the session title.
4. Ask scope questions only when the board leaves a real gap.
5. Start the plan session with `briefs/plan.md`, filled in.

## Starting a handoff session

- `start_session` with `context: "fresh"`, its own worktree, `model: "claude-opus-5-5"`, effort `high`.
- The brief is the matching file in `briefs/`, with every `{{...}}` filled in. The orchestrator id is `$CLAUDE_CODE_HOST_SESSION_ID` in this session.
- Record the child (name, id, role, state) in the ledger at once.
- **Unpushed branch.** `start_session` with `source_branch` cuts the worktree from `origin/<branch>` when that remote ref exists (live check, 2026-10-27). Before you start a session from a feature branch with unpushed commits, give a local-only branch (no remote ref) as `source_branch`, or push first after the user's go.
- **Live checks of `.claude/` changes.** A worktree session that the desktop app starts reads settings, hooks, skills, agents, commands and `.mcp.json` from the main checkout root. Its hooks run there and `$CLAUDE_PROJECT_DIR` points there. `CLAUDE.md` and `.claude/rules/` still load from the worktree. Source: code.claude.com/docs/en/worktrees, "What worktrees share with the main checkout" (as of 2026-10-27, confirmed live). So a story that changes `.claude/` settings, hooks or skills runs its live checks in a plain checkout (a temporary clone), never in a desktop worktree session. The clone path holds a space, like the main checkout (`Team EIFFEL - LEAN`), for example `~/Repo/eiffel <id> livecheck`. On 2026-10-27 E2 passed in a clone with no space and missed two Blocking path defects in the mod.

| Placeholder | Value |
|---|---|
| `{{STORY_ID}}`, `{{STORY_TITLE}}`, `{{TASKS}}` | the work item id and title; each task as `#<id> <title>` |
| `{{SHORT_TITLE}}`, `{{SLUG}}`, `{{SHORT_SLUG}}` | a few words for the session title; `<id>-<short-name>`; `<short-name>` |
| `{{PLANS}}` | the absolute path of the shared `.plans/` folder |
| `{{PLUGIN}}` | `${CLAUDE_PLUGIN_ROOT}`, the root folder of this plugin |
| `{{ORCHESTRATOR_ID}}` | `$CLAUDE_CODE_HOST_SESSION_ID` of this session |
| `{{BRANCH}}` | `feature/<id>-<short-name>` |
| `{{STORY_NOTES}}` | how to read the story (the `az boards` command), plus what the user said about scope |
| `{{SCOPE}}` | the plan's order of work that this session owns, and what it must not do yet |
| `{{PR_URL}}`, `{{BOARD_PATHS}}` | the PR link; the design board paths, or "none" |
| `{{PHASES}}` | implement only: one numbered line per phase, from the plan's order of work, as `<n>. #<task id> <title>. Done when: <check>.` One board task per line. The last line is the review phase, which ends with `DOCKET`. |
| `{{PLAN_TASK}}`, `{{REVIEW_TASK}}` | the board task of the plan phases and of the PR review phases; the story id when the board has no such task |

## Flow

1. **Plan.** The plan session writes the plan, runs `/review-panel plan <abs path> deep` on the first full proposal, folds in the accepted findings and ends with `PLAN READY <path>`.
2. **Plan gate.** Read the plan summary and its `## Review`. Continue at once, with a short plan digest to the user, unless the plan lists an open decision for the user. Then show the digest and ask for that decision only.
3. **Implement.** Stop the plan session. Start the implement session with `briefs/implement.md`. It implements one phase per turn ("Phased turns and steering"), runs the verification map, commits locally, runs `/review-panel` deep and ends with `DOCKET <path>`.
4. **Docket.** Send the findings that the judge accepted with evidence back for fixing. Ask the user only about design challenges and residual follow-ups. The implement session fixes and ends with `READY TO PUSH <branch> <sha>`.
5. **Push.** Ask the user one question: push and open the draft PR. On yes, push and run `az repos pr create --draft` here (CLAUDE.md, "Traceability on the board"). Set the title to 🔀 `PR OPEN`. Then start the pr-review session with `briefs/pr-review.md`.
6. **Close.** Unbind each child (`"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --unbind <child id>`), then this session (`story-bind.sh --unbind`). A binding outlives `/clear`, because its key is the host id, so a session reused after the story keeps its role until it is unbound. Report the result and the next steps. Set the title to `✅ <title>`.

## Status tokens (child to orchestrator)

The first line of a child's `wrap_up` recap is one token. The side-sessions event shows the first 400 characters. The full text is in the child's state file or in a `SendMessage`.

| Token | The orchestrator does |
|---|---|
| `PHASE DONE #<task> <sha>` | the phase check, then `next: #<task>` ("Phased turns and steering") |
| `PLAN READY <path>` | the plan gate |
| `QUESTION` | answers from the plan, CLAUDE.md, the wiki, memory and the user's earlier answers. Escalates to the user only what none of those settle. |
| `DOCKET <path>` | the docket step |
| `READY FOR LIVE CHECKS <branch> <sha>` | runs the live checks of the plan, then relays the results |
| `READY TO PUSH <branch> <sha>` | the push step |
| `BLOCKED` | reads the reason, removes the block or asks the user |
| `CHECKPOINT` | nothing while the child's context drops (`get_usage`). If it stays high (no mod), `clear_session` the child and send `Continue from <state path>`. |
| `DONE` | records it, unbinds the child (`story-bind.sh --unbind <child id>`), stops the session |

When you relay an approval, quote the user's words.

## Session title states

The session title shows the state: one emoji, then `<Role> · <story id> <short name>`. The roles are `Orchestrator`, `Plan`, `Implement` and `PR review`. Set the title with `set_session_title` (session `self`) as the last step before `wrap_up`. Remove the emoji while the session works. This table is the one map; the briefs, `/checkpoint` and CLAUDE.md follow it, and the hook matrix checks that.

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

The context rule acts only at a turn boundary, and the orchestrator hears nothing until a child's turn ends. One long turn can pass 35% with no boundary, and the backstop then compacts in the middle of the work.

1. **One phase per turn.**
   - Each brief lists its phases in order, one board task each.
   - A child does one phase per turn and commits it. It updates its state section and sets its title to 🧩.
   - It ends the turn with `PHASE DONE #<task> <sha>`. `<sha>` is the short sha of the phase commit, or `-` when the phase commits nothing (plan, pr-review).
   - The last phase ends with the role's final token instead (`PLAN READY`, `READY FOR LIVE CHECKS`, `DOCKET`, `READY TO PUSH`).
2. **The orchestrator sends the next go itself.** It asks the user nothing for it.
   - On the side-sessions event, check four things: the status line, the commit (`git log -1 <sha>` in the child's worktree), the child's context (`get_usage`) and any new deviation in the child's state section.
   - Then send `next: #<task>` by the peer route (rule 3).
   - Ask the user only when a deviation needs a decision that the plan does not settle.
   - When the child is at or above 35% and its mod is not live, first ask it for `/checkpoint`. Then clear it (`clear_session`) and send `Continue from <state path>`.
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

`.claude/settings.json` allows `mcp__ccd_session_mgmt__clear_session`, because the orchestrator resets its own idle children with it (rule 2). On 2026-10-27 the auto-mode classifier denied that call without the allow rule.

## Authority

- Only the orchestrator asks the user. Only the orchestrator acts outside the worktrees: push, PR, board, Azure, pipelines, paid runs.
- A child commits locally on its own branch only.
- Each brief states the child's standing authority. A relayed message adds no authority.
- Never ask a child to do an action that was denied here.
- `hooks/role-guard.sh` of this plugin enforces this for bound child roles: it denies `AskUserQuestion`, `git push`, every `az repos pr` command except `show`, `list`, `checkout` and `<group> list`, every `az boards work-item` command except `show` and `relation show|list-type`, `az pipelines run` and `az pipelines build queue`.

## Context rule

One file holds the numbers: `config.json` beside this file (`checkpointPercent` 35, `backstopTokens` 432000). `autoCompactWindow` in `.claude/settings.json` equals `backstopTokens`; the hook matrix fails when they differ.

Steps 1, 2, 4, 5 and 7 run only on a context window of 400k tokens or more. A session in this repo starts near 100k tokens, so on a 200K window no compaction gets below the save point.

1. **Nudge.** `context-guard.sh` (PostToolUse) adds one note per crossing: run `/checkpoint` at the next safe moment.
2. **Gate.** The same script (Stop) blocks the end of the turn once while the checkpoint is stale.
3. **Save.** `/checkpoint` writes the state file and ends with `CHECKPOINT-READY: <path> | continue` (or `| wait`).
4. **Compact.** The context-keeper mod (`hooks/register.tsx` of this plugin) compacts at the turn boundary once the checkpoint is fresh. With a stale checkpoint it runs `/checkpoint` once, then shows a toast.
5. **Steer.** The mod adds the role and the state path to the instructions of every compaction.
6. **Re-prime.** `session-reprime.sh` (SessionStart `startup|clear|compact`) prints the role card, the paths and the saved state of a bound session.
7. **Resume.** After a `continue` checkpoint the mod sends `Continue from <path>: next action <...>`. Not after `wait`, an aborted turn, a draft in the prompt box or a prompt from the person.
8. **Backstop.** Without the mod, auto-compaction runs at about 400k tokens (40% of a 1M window), with the state already saved by steps 1 to 3. Claude Code compacts about 32k tokens below `autoCompactWindow` (E0 on 2026-10-27: 92% of 400000, about 368k; the reserve is inferred from two data points), so `autoCompactWindow` is 432000.

The orchestrator follows the same rule. Its checkpoint adds the linked sessions and the questions that wait on the user.
