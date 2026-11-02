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
- For `/review-panel:review-panel`: the Codex CLI and the Codex Claude Code plugin (`openai-codex`). The versions must match `skills/review-panel/scripts/pins.sh`: codex-cli 0.153.4 and companion 1.0.6 (as of 2026-11-02).
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

With `/story` (the story-workflow plugin), set the `review` block of `.claude/story.json`:

```json
"review": {
  "plan": "/review-panel:review-panel plan {plan} deep",
  "changes": "/review-panel:review-panel deep",
  "pr": "/review-panel:review-panel PR deep",
  "fallback": "/review-panel:review-grok"
}
```

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
claude plugin validate .
```

The matrix runs every guard against fixture repos with fake `codex`, `gh`, `az` and `grok` binaries. No model runs. It exits 0 when every case passes. Each guard has a case that fails without it.

## Known limits

- The pins are strict. A Codex, companion or Grok update stops the panel until the pin is re-verified and bumped. `REVIEW_PANEL_ALLOW_UNPINNED=1` or `REVIEW_GROK_ALLOW_UNPINNED=1` allows one run with a warning.
- The panel reads no pull request threads. The judge asks for them, so a finder never sees prior feedback.
- One run is one sample. A quiet panel means the change survived this sample, not that it is correct. The tests of the repo decide that.
- Grok has no kernel sandbox by default (`REVIEW_GROK_SANDBOX=<profile>` adds one). Its read-only state comes from the tool allowlist and a check after the run.
