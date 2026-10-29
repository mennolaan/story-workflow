---
name: checkpoint
description: Save this session's state to its checkpoint file, so a compaction or a /clear loses nothing. Run it when the context guard says the context passed the save point, or before a planned /clear. Writes at most 60 lines, newest facts first, and ends with the CHECKPOINT-READY sentinel line.
---

# Checkpoint

Save the state of this session while you still hold the context. No hook can make you write it later.

## 0. Check the repo

Run step 1. When `story-bind.sh` exits 1, stop: show its message and write no file. It names `.claude/story.json` and `story.example.json`, because the story workflow is off in a repo without that file.

## 1. Find the target

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --state
"${CLAUDE_PLUGIN_ROOT}/hooks/story-bind.sh" --show
```

- `--state` creates its folder and prints the path. A bound session writes `<plans>/<slug>.d/<role>.md`. An unbound session writes `<plans>/.sessions/<key>.md`.
- `--show` prints the role, the story and the orchestrator id.
- Write the whole file again each time. Do not append.

## 2. Write the content

At most 60 lines. Newest facts first. Facts only, no narration.

Write the file with one Bash command: a quoted heredoc to the absolute path that step 1 printed.

```bash
cat > "<path>" <<'CHECKPOINT_EOF'
...the whole file...
CHECKPOINT_EOF
```

Never use the Write or Edit tool for this file. In a desktop worktree session the app refuses Write and Edit on a path in the main checkout, and the state path is there.

Header:

```
# Checkpoint <role> <slug> <UTC time>
Context <N>% · branch <branch> · HEAD <short sha>
```

Then these sections, in this order. Write "none" in an empty section.

1. `## Goal`: the outcome of this session, one line.
2. `## Where we are`: the current step and its state.
3. `## Done and verified`: each item with its evidence (command and result, commit sha).
4. `## Tried and failed`: what did not work, and why, so nobody tries it again.
5. `## Decisions`: the user's decisions in their own words, and the options they rejected.
6. `## Unverified assumptions`: what you believe and did not check.
7. `## Working tree`: the paths you changed and the files not committed.
8. `## Open questions`: for the orchestrator (a child) or for the user (the orchestrator).
9. `## Next action`: one line, the exact command or step. The resume prompt quotes this line.

The orchestrator adds two sections after `## Open questions`:

- `## Linked sessions`: name, id, role and state of each child.
- `## Waiting on the user`: each question, with the time it was asked.

## 3. End with the sentinel

The last line of the file is exactly:

```
CHECKPOINT-READY: <absolute path of this file> | continue
```

- Use `continue` when the next action needs no answer from anyone. After the compaction the context-keeper mod sends "Continue from <path>: next action <...>".
- Use `wait` when the next action waits on the orchestrator or the user. Then nothing resumes by itself.

## 4. Then

- Read the file back once. Check the line count and the sentinel.
- Finish the turn as planned. The context-keeper mod compacts at the turn boundary. Without the mod, the backstop compacts later, at about 400k tokens (40% of a 1M window).
- A child session ends its turn with `wrap_up`, recap first line `CHECKPOINT`. Before `wrap_up`, a story session sets its title to 💾 `CHECKPOINT` plus `<Role> · <story id> <short name>` (`${CLAUDE_PLUGIN_ROOT}/skills/story/SKILL.md`, "Session title states").
