# story-workflow

A Claude Code plugin that runs one board story through one orchestrator session. Handoff sessions plan, implement and review. Only the orchestrator asks you questions and acts outward (board, push, PR). Every session saves its state at 35% context and compacts at the next turn boundary, with no keystroke from you.

The plugin holds:

- `/story <id>`: makes the session the orchestrator of one story.
- `/checkpoint`: saves the state of a session before a compaction or a `/clear`.
- Hooks: a role guard for the child sessions, the context rule, the re-prime after a compaction, the compaction trail, and an optional plan-boundary reminder.
- The context-keeper mod: compacts at the turn boundary and resumes from the saved state.

The plugin does nothing in a repo without `.claude/story.json`. Install it once, then turn it on per repo.

## Requirements

- The Claude desktop app (Code tab) for `/story`. The orchestrator starts, resets and renames its sessions with the session tools of the app. One bound session also works in the terminal CLI.
- Claude Code 2.1.308 or later. Earlier versions refuse the mod. Tested on 2.1.312 (2026-10-28).
- `jq` and `git` on PATH.
- Read access to this private repo, and a git credential for github.com on your machine. The install does not ask for one. Run `gh auth login`, then `gh auth setup-git`, or add an SSH key to your GitHub account.

## Install

In a terminal:

```bash
claude plugin install story-workflow --marketplace mennolaan/story-workflow
```

This adds the marketplace `story-workflow` to your user settings and installs the plugin at user scope. Tested on 2026-10-28.

In the desktop app: click + next to the prompt box, then Plugins, then Add marketplace with `mennolaan/story-workflow`, then Add plugin. This path comes from the Claude Code plugin reference and was not tested here.

Start a new session after the install. A running session keeps the plugins it loaded at start.

Without access to the repo, the install stops with `Permission denied (publickey)` and `Could not read from remote repository`. Ask the owner for access, then set up the credential (see "Requirements").

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
| `checkpointPercent` | Save point in percent of the context window. Default 35. |
| `backstopTokens` | The highest allowed `autoCompactWindow`. Default 432000. |
| `baseBranch` | The branch that feature branches start from and PRs target, for example `main`. |
| `branch` | The feature branch name. `{id}` is the work item id, `{slug}` the short name. |
| `board.show` | The command that prints a story and its tasks. `{id}` is the work item id. |
| `pr.create` | The command that opens a draft PR. Placeholders: `{branch}`, `{base}`, `{ids}`, `{title}`, `{description}`. Without it the orchestrator asks you how to open the PR. |
| `review` | Optional. `plan` (`{plan}` is the plan path), `changes`, `pr`, and `fallback` (run when the review command stops because a tool is missing). Without it the sessions skip the review and say so. |
| `guard.deny` | Extra Perl regexes. The role guard splits a shell command into simple commands, removes the quotes, and joins the words of each simple command with single spaces. A regex that matches that text (with `/m`) denies the child session the command. It also sees the scripts that the command runs: `bash -c`, `eval`, `$(...)` and heredocs fed to a shell. A regex also matches argument text, so anchor it with `^` to match only a command, for example `^terraform\\s+apply\\b`. |
| `planBoundary` | `true` turns on the plan-boundary reminder and its stamp hook. Default `false`. |
| `conventions` | Not read yet. The briefs send each session to the repo's `CLAUDE.md` for its conventions and checks. |

The role guard always denies a child session `AskUserQuestion`, `git push`, `gh pr` and `gh issue` mutations, `gh api` writes, `az repos pr` and `az boards work-item` mutations, `az pipelines run` and `az pipelines build queue`. It checks the Bash tool and the terminal tool. Only the orchestrator acts outward.

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

- The role guard is a deny list, not a sandbox. It does not catch a quoted verb such as `gh pr "merge" 5`, a child session that unbinds itself with `story-bind.sh`, or MCP tools that act outward.
- The backstop check reads `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and the user, project, local and managed settings files. It does not see `--settings`, `--autocompact`, server-managed settings or the managed settings of an embedding host.
- Mod modules are early access, and their API can change between Claude Code releases. Run the checks after you update Claude Code.
