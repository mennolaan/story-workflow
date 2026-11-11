# review-panel

A Claude Code plugin for code review before and after a pull request, and for plan files. Codex (or Grok) finds. The main thread of your session judges every finding against the repo and a dated fact sheet, and presents a docket. Nothing is changed until you say so.

The plugin holds:

- `/review-panel:review-panel`: one Codex adversarial review over a prepared scope, or the stance heads in deep mode.
- `/review-panel:review-grok`: the same procedure with Grok (xAI Grok Build CLI) as the finder, for a reviewer without a Codex account or as a second model family.
- The scripts: `prepare-scope.sh` (the exact scope and its manifest), `run-adversarial.sh`, `run-heads.sh`, `run-grok.sh`, `check-docket.sh` (proves every suggestion block replaces exactly its anchor) and `profile.sh`.
- The head library: delivery, dependency, identity, reach, falsify, parity, situate, conform, daytwo, invariants and ux.

## Requirements

- Claude Code 2.1.308 or later. Tested on 2.1.312 (2026-11-02).
- `git`, `python3` and `node` on PATH.
- For Codex deep/plan review: codex-cli 0.167.0 and access to `gpt-6.1-sol`. Its exec flags were checked locally on 2026-11-08; runner tests use fake Codex, without a paid model call.
- For default single-pass Codex review: codex-cli 0.153.4 or 0.167.0 and the Codex Claude Code plugin (`openai-codex`) companion 1.0.6. With 0.167.0 one codex binary runs both modes. The pins live in `skills/review-panel/scripts/pins.sh`.
- For `/review-panel:review-grok`: the Grok Build CLI (`curl -fsSL https://x.ai/cli/install.sh | bash`, then `grok login`) at the version in `skills/review-grok/scripts/lib.sh` (1.0.46). Grok sends the reviewed code to xAI.
- Optional: `gh` or `az repos` to list the open sibling pull requests in the scope.

## Install

```bash
claude plugin install review-panel --marketplace mennolaan/story-workflow
```

The marketplace is public, so the install needs no credential. Start a new session after the install. To run it from a clone, add the absolute path of `plugins/review-panel` in the clone to `env.CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json`, and do not also install it from the marketplace.

## Use it

```text
/review-panel:review-panel                          # the branch against the base ref of the profile
/review-panel:review-panel uncommitted work         # the working tree against HEAD
/review-panel:review-panel PR 84 deep               # pull request 84, the stance heads
/review-panel:review-panel plan .plans/my-plan.md   # a design review of a plan file
/review-panel:review-grok deep                      # the same, with Grok as the finder
```

Add `.claude/.review/` to the `.gitignore` of the repo. The scopes live there.

Codex deep reviews and plan reviews require **`gpt-6.1-sol`**. The runner
passes the model explicitly for every head, overriding the global Codex default,
and rejects any different `--model` value. If the model is unavailable the review
fails; it never substitutes an older Sol or Astra. Reasoning effort remains
independent. Default single-pass Codex review and the separate Grok runner keep
their own configuration. Global Codex defaults live in `~/.codex/config.toml`.

With `/story` (the story-workflow plugin), set the `review` block of `.claude/story.json`:

```json
"review": {
  "plan": "/review-panel:review-panel plan {plan} deep",
  "changes": "/review-panel:review-panel deep",
  "pr": "/review-panel:review-panel PR deep",
  "fallback": "/review-panel:review-grok"
}
```

## Review teammates' pull requests (Azure DevOps)

`/review-panel:configure-prs` reviews your teammates' pull requests as they come
in, so nobody has to ask for a review. Open a session in any repo and run it:

```text
/review-panel:configure-prs
```

- It asks for the Azure DevOps URL to watch: a project
  (`https://dev.azure.com/<org>/<project>`) or repos (`.../_git/<repo>`). You
  can also pass the URLs right away. It saves them, with your identity from
  `az account show`, in `~/.claude/review-watch/config.json`, and starts polling.
- In a later session, run it again without a URL: it reuses the saved config
  and starts polling. Pass a URL to replace the config.
- A script polls every 30 minutes on weekdays from 08:00 to 18:00. It uses no
  model: the session waits at zero tokens and wakes only when an active PR that
  is not yours, not a draft and not from a pipeline identity (Build Service) has
  commits it has not reviewed.
- The session then starts one review run per PR and spends no tokens on it
  itself. The run checks out the PR and runs review-panel deep mode with 9
  Codex heads (delivery, dependency, identity, parity, situate, reach, falsify,
  conform, invariants). It then starts a headless Claude Code judge:
  `claude -p --model claude-opus-5-5 --effort medium --autocompact 500k`. The
  judge verifies the findings and posts on the PR: one inline comment per
  Blocking or Should-fix finding (at most 10) and one summary. The summary
  marks the reviewed commit, so a PR is reviewed again only after new commits,
  and then only the new changes.
- Desktop does not let a session start another session from a turn that a
  background task woke, so the judge is a headless run, not a sidebar session.
  Its log, the head outputs and the docket stay in
  `~/.claude/review-watch/scopes/`.
- The judge works in the PR checkout. It may write only its docket and run only
  read-only git commands, `watch.py threads` and `watch.py post`.
- Change the judge or the heads on the first run: `--model`, `--effort`,
  `--context-cap` (default 500k), `--max-budget-usd` (an optional spend cap per
  PR) and `--heads a,b,c`.
- It never votes, approves or completes a PR, never runs the PR's code and posts
  only comments. They post under your Azure DevOps identity and say they are
  automated.
- One poller per machine; a second session that starts one is told that another
  session is already watching. The session must stay open; a closed app or a
  sleeping Mac pauses the watch.
- Needs `az` with the `azure-devops` extension, logged in (`az login`), plus
  the review-panel requirements (Codex and its companion).

Cost: nothing while waiting. Each review is 9 Codex runs on your OpenAI account,
plus one Opus 5.5 judge run whose context is capped at 500k tokens.

## The review profile

Without a profile the panel reads CLAUDE.md and AGENTS.md for the repo rules, and runs on its generic prompts. A profile makes the finders and the judge know your project. Put it in `.claude/review-profile/` of the repo and commit it. Every file is optional. `profile.example/` in this plugin is a complete example.

| File | Read by | Holds |
|---|---|---|
| `profile.json` | the scripts | the keys below |
| `context.md` | every finder prompt | the project rules: invariants, locked decisions, what not to flag in this repo, who sees a defect |
| `judge.md` | the judge | the checks that must be green, the severity order, where PR threads live, where declined findings are answered |
| `heads/<head>.md` | that head | project detail appended to the generic head (sibling folders, the store that counts as durable), or a head of its own |

`profile.json` keys:

| Key | Default | Meaning |
|---|---|---|
| `name` | the repo folder name | the project name in every prompt |
| `baseRef` | `origin/HEAD`, else `origin/main`, else `origin/master` | the base of a branch review, and the branch for the recent-commits list of Grok |
| `prHost` | `auto` (from the `origin` URL) | `github`, `azure-repos` or `none`: how the scope lists open sibling pull requests |
| `harnessPaths` | none | paths added to the review harness (the profile folder, `.claude/settings.json`, `CLAUDE.md`, `AGENTS.md`). A path that ends in `/` is a folder. A change to one sets `HARNESS_CHANGED` |
| `deepHeads` | delivery, dependency, identity, parity, situate, reach, falsify | the heads of a deep review |
| `planHeads` | delivery, conform, situate | the heads of a plan review |

An unknown key, a wrong type or a bad `prHost` fails loud. `REVIEW_PANEL_PROFILE=<folder>` points at a profile outside the repo.

Print the resolved profile:

```bash
"<plugin root>/skills/review-panel/scripts/profile.sh" show
```

## Check it

```bash
tests/review-panel-matrix.sh
```

```bash
python3 tests/configure-prs.test.py
```

```bash
claude plugin validate .
```

The matrix runs every guard against fixture repos with fake `codex`, `gh`, `az` and `grok` binaries. No model runs. It exits 0 when every case passes. Each guard has a case that fails without it.

## Known limits

- The pins are strict. A Codex, companion or Grok update stops the panel until the pin is re-verified and bumped. `REVIEW_PANEL_ALLOW_UNPINNED=1` or `REVIEW_GROK_ALLOW_UNPINNED=1` allows one run with a warning.
- The panel reads no pull request threads. The judge asks for them, so a finder never sees prior feedback.
- One run is one sample. A quiet panel means the change survived this sample, not that it is correct. The tests of the repo decide that.
- Grok has no kernel sandbox by default (`REVIEW_GROK_SANDBOX=<profile>` adds one). Its read-only state comes from the tool allowlist and a check after the run.
