# story-workflow

A Claude Code plugin that runs one board story through one orchestrator session. Handoff sessions plan, implement and review. Only the orchestrator asks you questions and acts outward (board, push, PR). Every session saves its state at its save point (350k tokens for a 1M model) and compacts at the next turn boundary, with no keystroke from you.

The plugin holds:

- `/story <id>`: makes the session the orchestrator of one story.
- `/checkpoint`: saves the state of a session before a compaction or a `/clear`.
- The story-reader agent: reads stories, tasks and issues on haiku and returns a digest.
- Hooks: a role guard for the child sessions, a board-read guard that keeps board reads in the story-reader agent, the context rule, the re-prime after a compaction, the compaction trail, and an optional plan-boundary reminder.
- The context-keeper mod: compacts at the turn boundary and resumes from the saved state.

The plugin does nothing in a repo without `.claude/story.json`. Install it once, then turn it on per repo.

## Requirements

- The Claude desktop app (Code tab) for `/story`. The orchestrator starts, resets and renames its sessions with the session tools of the app. One bound session also works in the terminal CLI.
- Claude Code 2.1.308 or later. Earlier versions refuse the mod. Tested on 2.1.312 (2026-10-28).
- `jq` and `git` on PATH.
- Network access to github.com. The repo is public, so the install needs no GitHub account or credential.

## Install

In a terminal:

```bash
claude plugin install story-workflow --marketplace mennolaan/story-workflow
```

This adds the marketplace `story-workflow` to your user settings and installs the plugin at user scope. Tested on 2026-10-28 with no git credential.

In the desktop app: click + next to the prompt box, then Plugins, then Add marketplace with `mennolaan/story-workflow`, then Add plugin. This path comes from the Claude Code plugin reference and was not tested here.

Start a new session after the install. A running session keeps the plugins it loaded at start.

Update and remove:

```bash
claude plugin update story-workflow@story-workflow
```

```bash
claude plugin uninstall story-workflow@story-workflow
```

An update applies to sessions that start after it.

### Run it from a clone

To work on the plugin, clone this repo and add the clone to `env.CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` (absolute paths, separated by `:`). Each new session then loads the clone, and `git pull` updates it. Do not also install it from the marketplace, or every hook runs twice.

## Turn it on in a repo

1. Copy `skills/story/story.example.json` of this plugin to `.claude/story.json` in the repo. Set the values for that repo and commit the file.
2. Set `"autoCompactWindow"` in `.claude/settings.json` of the repo to `backstopTokens` (432000) or lower. A plugin cannot set this key. When the effective value is missing or higher, `story-bind.sh` refuses to bind and `/story` stops with the fix.
3. Start a new session in the repo and run `/story <id>`.

### `.claude/story.json`

| Field | Meaning |
|---|---|
| `checkpointPercent` | Save point in percent of the model window. Default 35. The save point is `checkpointPercent` (35) of the model window: 350k tokens for a 1M model (Opus 5.5, Fable). The desktop composer and `/context` show percent of `autoCompactWindow` (432000), so the save point shows as 81% there and the backstop compaction starts at 92%. |
| `backstopTokens` | The highest allowed `autoCompactWindow`. Default 432000. |
| `baseBranch` | The branch that feature branches start from and PRs target, for example `main`. |
| `branch` | The feature branch name. `{id}` is the work item id, `{slug}` the short name. |
| `board.show` | The command that prints a story and its tasks. `{id}` is the work item id. The story-reader agent runs it. Its words before the first `{` word or option count as a board read, for example `gh issue view`. |
| `board.reader` | `false` turns the board-read guard off. Default on. |
| `board.reads` | Extra board read commands, as Perl regexes. They match like `guard.deny`, for example `^jira\\s+issue\\s+view\\b`. |
| `board.readTools` | MCP tools that read the board, as Perl regexes. A regex must match the whole tool name, for example `mcp__github__(get_issue\|list_issues\|search_issues)`. Only the story-reader agent may call them. |
| `pr.create` | The command that opens a draft PR. Placeholders: `{branch}`, `{base}`, `{ids}`, `{title}`, `{description}`. Without it the orchestrator asks you how to open the PR. |
| `review` | Optional. `plan` (`{plan}` is the plan path), `changes`, `pr`, and `fallback` (run when the review command stops because a tool is missing). Without it the sessions skip the review and say so. |
| `guard.deny` | Extra Perl regexes. The role guard splits a shell command into simple commands, removes the quotes, and joins the words of each simple command with single spaces. A regex that matches that text (with `/m`) denies the child session the command. It also sees the scripts that the command runs: `bash -c`, `eval`, `$(...)` and heredocs fed to a shell. A regex also matches argument text, so anchor it with `^` to match only a command, for example `^terraform\\s+apply\\b`. |
| `guard.denyTools` | Extra MCP tool names, as Perl regexes. A regex must match the whole tool name, for example `mcp__github__.*`. The role guard denies a child session every call to a tool that matches one. |
| `planBoundary` | `true` turns on the plan-boundary reminder and its stamp hook. Default `false`. |
| `conventions` | The file that holds the conventions and checks of the repo. The briefs send each session to it. Default `CLAUDE.md`. |

The role guard always denies a child session `AskUserQuestion`, `git push`, `gh pr` and `gh issue` mutations, `gh api` writes, `az repos pr` and `az boards work-item` mutations, `az pipelines run` and `az pipelines build queue`. It checks the Bash tool and the terminal tool. It also denies a child session every write to the binding files in `.plans/.sessions/`: Edit, Write and NotebookEdit on a path there, and `rm`, `mv`, `cp`, `tee`, `truncate`, `ln`, `sed -i`, `>` or `>>` in a shell command. `story-bind.sh` refuses a child that unbinds itself or binds again with another role, story or parent. Only the orchestrator of a child unbinds it. The orchestrator runs `story-bind.sh --adopt <child id>` after it starts a child, and only then does `clear_session` of that child run without a prompt: the guard also checks that the child's binding names the orchestrator as parent and carries its own file key. It also denies a child these MCP tools: `mcp__ccd_pr__*` except `get_status`, `start_session`, `move_to_cloud`, `clear_session`, the session tools that archive, delete, stop, detach, message or reconfigure a session, `set_session_title` for any session but its own, and the host tools that sync or clean up worktrees. `mcp__ccd_turn__*` and read-only tools stay open. Only the orchestrator acts outward.

## Board reads

A story or issue read returns large JSON. On the session model all of it stays in the context. `hooks/board-read-guard.sh` runs these reads in the story-reader agent (`agents/story-reader.md`) on haiku, which returns a short digest. The digest copies the description, the acceptance criteria and an issue body in full.

- Every thread except the story-reader agent is denied a board read: the main thread of every session, and every other agent. The deny names the agent to use.
- Board reads: `az boards work-item show` and `relation show`, `az boards query`, `az devops invoke` and `az rest` on work items (GET, or a POST of `wiql` or `workitemsbatch`), `gh issue view|list|status`, `gh search issues`, `gh project item-list`, `gh api` reads of issues and `gh api graphql` queries on issues, the command of `board.show`, each regex in `board.reads`, and each MCP tool in `board.readTools`. A `gh api graphql` document with a mutation operation is a write. The guard ignores comments and strings in the document. A command that the guard knows keeps its class, and a command of `board.show` or `board.reads` that the role guard denies is a write.
- The story-reader agent only reads. The guard denies it every board and issue write, every rule of the role guard (`git push`, `gh pr` writes, `az pipelines run`, `guard.deny`, the binding files), and every MCP tool outside `board.readTools`. It has no Edit, Write, NotebookEdit or Agent tool.
- A story-reader spawn needs `model: "haiku"` on the Agent call. A repo can hold its own `story-reader` agent with another model, so the guard does not trust the frontmatter of any reader. While `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` sets every subagent to a model that is not haiku, the guard denies the spawn.
- The story-reader agent is a subagent with `agent_id` and `agent_type` `story-workflow:story-reader` (or `story-reader`) in the hook input. A main thread started with `--agent story-reader` has no `agent_id`, so it is not the reader.

## Check it

```bash
tests/story-hooks-matrix.sh
```

```bash
claude plugin validate .
```

```bash
claude plugin test .
```

The matrix exits 0 when every case passes. Each gate has a case that fails without the gate.

## Known limits

- The role guard is a deny list, not a sandbox. It reads shell words, so quoting, wrappers (`env`, `sudo`, `timeout`, `find -exec` and others), `bash -c`, `eval` and heredocs do not hide a verb. It denies a command whose name it cannot read (`$x push`, `{git,push}`). It cannot see what a script does: a child can still run `git push` or write the binding files from a script in another language (`python3 -c`), or from a script file that it wrote first. Treat the guard as a stop for mistakes, not for a determined session.
- `story-bind.sh` takes the identity of the caller from `CLAUDE_CODE_HOST_SESSION_ID` and `CLAUDE_CODE_SESSION_ID`. The guard denies a child any command that sets `CLAUDE_CODE_*`, `STORY_*`, `CLAUDE_PROJECT_DIR` or `CLAUDE_CONFIG_DIR`, so a child cannot act as its orchestrator. A script in another language can still set them.
- The guard does not know an MCP tool that is not in its list. Name such tools in `guard.denyTools`, for example the browser servers (`mcp__claude-in-chrome__.*`, `mcp__Claude_Browser__.*`), which can click through a PR page.
- `gh api graphql` is a POST for gh, so the guard denies it for a child. A review session that needs review threads asks the orchestrator.
- Bash and zsh differ in rare syntax. The guard parses bash-like syntax and denies a command that it cannot parse.
- The backstop check reads `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and the user, project, local and managed settings files. It does not see `--settings`, `--autocompact`, server-managed settings or the managed settings of an embedding host.
- The board-read guard is a cost gate, not a security boundary. It does not see a read inside a script file, in another language (`python3 -c`), with `curl`, or in Codex. A mod whose `agent.spawn` hook sets a model overrides the `model` of the Agent call. A Workflow script that calls `agent()` with the reader type does not go through the Agent tool, so the spawn check does not see its model.
- The digest is only as exact as the copy that haiku makes. The reader copies the acceptance criteria word for word. Check them against the board when a decision depends on one word.
- Mod modules are early access, and their API can change between Claude Code releases. Run the checks after you update Claude Code.
