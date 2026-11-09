# story-workflow

A Claude Code plugin that runs one board story through one orchestrator session. Handoff sessions plan, implement and review, with explicit model/effort routing and bounded scope. Independent tracks run in parallel worktrees. Only the orchestrator asks you questions and acts outward (board, push, PR). Small independent handoffs reduce repeated compaction; checkpoint and compaction remain available when needed (save point: 350k tokens for a 1M model).

The plugin holds:

- `/story <id>`: makes the session the orchestrator of one story.
- `/checkpoint`: saves the state of a session before a compaction or a `/clear`.
- `/documentation assess|update|verify <scope>`: checks plan/doc consistency, assigns doc ownership and verifies affected documentation with the integrated behavior.
- `/requirements refine|verify <scope>`: turns sourced PO intent into testable requirements and derives requirement-to-evidence coverage at completion.
- Native behavioral evals under `evals/`: outcome/process cases for every skill/agent, plus workflow preflight and routing decisions. See [evals/README.md](evals/README.md).
- The story-reader agent: reads stories, tasks and issues on haiku and returns a digest.
- The source-reader and test-runner agents: fetch named documentation sources and run prescribed checks on Haiku/low, returning bounded evidence.
- Optional requirements-reviewer, architect-reviewer and documentation-reviewer agents: challenge requirements, design boundaries and documentation/evidence gaps. The orchestrator chooses existing-owner work versus an agent/handoff and resolves model/effort per invocation.
- `hooks/story-route.sh`: validates task routing and context estimates, resolves explicit model/effort settings, and flags large handoffs for possible parallel decomposition.
- `hooks/story-review.sh`: freezes approved acceptance criteria, captures revision-bound check evidence and runs bounded read-only Codex reviews for foundation, handoffs and the integrated story.
- Hooks: a role guard for the child sessions, a board-read guard that keeps board reads in the story-reader agent, the context rule, the re-prime after a compaction, the compaction trail, and an optional plan-boundary reminder.
- The context-keeper mod: compacts at the turn boundary and resumes from the saved state. A checkpoint more than 3 turns old is saved again first.

The plugin does nothing in a repo without `.claude/story.json`. Install it once, then turn it on per repo.

This marketplace also holds the `review-panel` plugin (`plugins/review-panel/`): code and plan review with Codex or Grok as the finder and the main thread as the judge. `/story` can use it as its review command. See [plugins/review-panel/README.md](plugins/review-panel/README.md).

## Requirements

- The Claude desktop app (Code tab) for `/story`. The orchestrator starts, resets and renames its sessions with the session tools of the app. One bound session also works in the terminal CLI.
- Claude Code 2.1.308 or later. Earlier versions refuse the mod. Tested on 2.1.312 (2026-10-28).
- `jq` and `git` on PATH.
- Python 3 and an authenticated Codex CLI for acceptance evidence and independent handoff review (CLI integration checked against 0.153.4).
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
| `review` | Optional. `plan` (`{plan}` is the plan path), `changes`, `pr`, and `fallback` (run when the review command stops because a tool is missing). Without it sessions skip these configured panels and say so; optional planning specialists and scoped Codex gates still apply. |
| `guard.deny` | Extra Perl regexes. The role guard splits a shell command into simple commands, removes the quotes, and joins the words of each simple command with single spaces. A regex that matches that text (with `/m`) denies the child session the command. It also sees the scripts that the command runs: `bash -c`, `eval`, `$(...)` and heredocs fed to a shell. A regex also matches argument text, so anchor it with `^` to match only a command, for example `^terraform\\s+apply\\b`. |
| `guard.denyTools` | Extra MCP tool names, as Perl regexes. A regex must match the whole tool name, for example `mcp__github__.*`. The role guard denies a child session every call to a tool that matches one. |
| `planBoundary` | `true` turns on the plan-boundary reminder and its stamp hook. Default `false`. |
| `conventions` | The file that holds the conventions and checks of the repo. The briefs send each session to it. Default `CLAUDE.md`. |
| `parallel.max` | The most track sessions that run at once after the plan gate. Default 1, which keeps one implement session. With 2 or more, `/story` asks you once when the plan has two or more independent tracks. |
| `parallel.shared` | Globs of shared or generated files, for example lockfiles. A track task that claims one moves to the story-branch session. `*` also matches `/`, and `**/x` also matches `x` at the repo root. Default none. |
| `routing.startupTokens` | Estimated startup context per handoff. Default 100000, to be replaced by measurement for the consuming repo. Not a universal Claude Code overhead. |
| `routing.targetSessionTokens` | Advisory handoff context target, including startup and owned task input/work estimates. Default 200000. The resolver lowers the target to the model checkpoint or 85% of `backstopTokens` when earlier. Reaching it produces a sizing warning, not a launch refusal. Compaction remains allowed. This is not a spend limit or live meter. |
| `routing.profiles` | Optional per-profile overrides of `family` (`haiku`, `sonnet`, `opus`) and `effort` (`low`, `medium`, `high`, `xhigh`, `max`). Defaults below. Unknown profile/setting names fail validation. |
| `routing.models` | Optional per-family overrides of `id` and `window` (tokens), for example `{"sonnet":{"id":"my-sonnet-deployment","window":200000}}`. Defaults pin the Anthropic 5.5 IDs with 1M windows. Verify provider/model availability and supported effort levels before overriding. |

## Model routing and bounded handoffs

The orchestrator chooses profiles from the task's ambiguity, risk and checks. The
planner proposes one row per claim task in `<slug>.d/routing.json`, plus `merge`
and `review` overhead rows. Each row names `id`, `profile`, `inputTokens`,
`workTokens` and `reason`; see `skills/story/briefs/plan.md` for an example.

| Profile | Default model | Effort | Work |
|---|---|---|---|
| `planning` | Opus 5.5 | high | decomposition, architecture, conflicting evidence |
| `implementation` | Sonnet 5.5 | medium | specified features, writing tests, routine diagnosis |
| `complex` | Opus 5.5 | high | difficult diagnosis, security/concurrency decisions |
| `review` | Sonnet 5.5 | high | whole-story review and judging evidence |
| `requirements` | Sonnet 5.5 | medium | bounded requirements and acceptance-gap review |
| `documentation` | Sonnet 5.5 | medium | bounded documentation impact/consistency review |
| `retrieval` | Haiku 5.5 | low | fetch/extract named wiki, Confluence, docs or board facts |
| `verification` | Haiku 5.5 | low | execute known commands and extract failure evidence |

Before a plan session, resolve `hooks/story-route.sh plan`. At the plan gate:

```bash
hooks/story-route.sh --check /absolute/path/to/plan.md /absolute/path/to/routing.json
```

This checks exact task coverage and budgets the safe groups from
`story-groups.sh`, including dependency joins and moves to integration. Sequential
mode assesses the whole story and warns when it exceeds the planning target. Before each launch, resolve the exact owned scope:

```bash
hooks/story-route.sh implement-track /absolute/path/to/routing.json 102,103
```

The JSON output names the explicit model, effort, reason, estimate, target and
sizing/compaction warnings. Mixed tracks get the strongest model/effort they need.
The story branch includes merge/review overhead. Prefer more independent parallel
handoffs when they avoid repeated compaction and reduce total time/tokens. Keep
coupled work together when splitting adds more overhead, and checkpoint/compact
when needed. Exceeding the target does not block a launch. The example now permits ten parallel tracks; existing repo
configs retain their own cap. Ten is a ceiling for independent work, not a promise
of a speedup. Small retrieval/check jobs often fit a subagent better than a new
Desktop worktree session. Running a deterministic test directly can be cheapest.

The orchestrator applies the output using the live Desktop tool schema and
records requested/observed settings, estimates, sizing decisions, elapsed time, usage when available,
retries and compactions in the ledger. The resolver does not launch sessions or
enforce host settings. It refuses conflicting effort/forced-subagent settings
visible in its environment; Desktop and managed settings still need verification.
Never treat a model name written into a brief as proof of the effective model.
After one reproducible capability failure, route the remaining scope deliberately;
do not retry blindly or escalate a missing credential to a larger model.

### Optional planning specialists

The orchestrator assesses requirements, architecture and documentation review at intake and
again at the draft boundary. A clear routine story can keep these reviews with the existing owner, with reasons
in the ledger. Requirements review helps with ambiguous outcomes, conflicting
rules and missing failure/acceptance scenarios. Architecture review is useful
for unresolved cross-system contracts, migrations, security/concurrency risks
or uncertain track independence. It concentrates on contracts and ownership
that enable independent parallel implementation, rather than repeating planning.

These are read-only subagents, not extra implementation sessions. The starting
routes are Sonnet/medium for requirements and Sonnet/high for architecture;
the orchestrator can select another profile and effort for each question:

```bash
hooks/story-route.sh requirements-review --profile requirements --effort high
hooks/story-route.sh architect-review --profile complex --effort high
```

`--profile` and `--effort` apply only to these specialist roles. Profiles select
the configured family and default effort; `--effort` independently overrides
that effort. Existing provider/model overrides still apply. Pass the resolved
settings explicitly to the Agent call; agent frontmatter is only a fallback.
No default uses xhigh/max. No consuming-repo config migration is needed.

The orchestrator saves bounded input snapshots/reports, records requested and
observed settings (or `unverified`), and can run independent reviews in parallel.
The planner validates findings and revises the plan/acceptance scenarios; real
product decisions stay with the user. Selected reviews and blocking findings
must be resolved before acceptance freeze. One initial pass and at most one
focused correction check avoid review loops. Material scope/contract changes
require reassessment. Configured plan panels and implementation Codex gates
remain in place. Selection/completion is a workflow instruction, not an
executable semantic gate; the routing helper only validates launch settings.
See [the specialist protocol](skills/story/planning-review.md).

The role guard always denies a child session `AskUserQuestion`, `git push`, `gh pr` and `gh issue` mutations, `gh api` writes, `az repos pr` and `az boards work-item` mutations, `az pipelines run` and `az pipelines build queue`. It checks the Bash tool and the terminal tool. It also denies a child session every write to the binding files in `.plans/.sessions/`: Edit, Write and NotebookEdit on a path there, and `rm`, `mv`, `cp`, `tee`, `truncate`, `ln`, `sed -i`, `>` or `>>` in a shell command. `story-bind.sh` refuses a child that unbinds itself or binds again with another role, story or parent. Only the orchestrator of a child unbinds it. The orchestrator runs `story-bind.sh --adopt <child id>` after it starts a child, and only then does `clear_session` of that child run without a prompt: the guard also checks that the child's binding names the orchestrator as parent and carries its own file key. It also denies a child these MCP tools: `mcp__ccd_pr__*` except `get_status`, `start_session`, `move_to_cloud`, `clear_session`, the session tools that archive, delete, stop, detach, message or reconfigure a session, `set_session_title` for any session but its own, and the host tools that sync or clean up worktrees. `mcp__ccd_turn__*` and read-only tools stay open. Only the orchestrator acts outward.

## Documentation lifecycle, refinement and EDD

New stories first assess documentation constraints and impact, then preserve PO
intent in stable sourced requirements with observable positive/negative scenarios,
explicit unknowns/exclusions and bounded execution slices. The planner owns
`documentation.md` and `requirements.md` under the story folder. It puts docs in
the claims table with one writer; shared guides and cross-track docs belong to
integration. Approved changes, plan violations and stale/unverified sources need
distinct dispositions. The skills work standalone as draft/report procedures too.

Add `requirements` and `documentation` declarations to the acceptance contract;
see [the schema/protocol](skills/story/review.md). The strict freeze validates
reference coverage, including every criterion mapping to a sourced requirement.
At completion, `story-review.sh trace <slug> integrated all <base-sha>` derives
`traceability.json` from the current checks and independent review without an
extra model call. Missing runtime/publication proof remains unverified. Existing
contracts keep working but are labeled `TRACE LEGACY` until reassessed/migrated.

The orchestrator chooses whether work stays with its existing owner or warrants
an isolated read-only agent/owned handoff. Optional `documentation-review` starts
Sonnet/medium and `requirements-verify` starts Sonnet/high; both accept per-call
`--profile`/`--effort` and provider overrides through `story-route.sh`. Direct
known checks and named-source retrieval need no expensive reasoning. No new
consuming-repo config is required; effective host model/effort still needs checking.

Evaluation-driven development means defining regression tasks, expected/forbidden
behavior and graders before changing a policy/agent/skill, then checking process
and outcomes against baseline and held-out cases. The native suite covers every
agent and skill; deterministic Git/evidence/routing tests cover enforceable
invariants. A native text eval does not certify full Desktop coordination or
compaction. See [the eval run/coverage guide](evals/README.md), [research sources
and limits](skills/requirements/research.md), and [the synthetic PO-to-handoff
example](skills/requirements/examples/order-cancellation.md). No benchmark result
is inferred from writing a case or passing a stubbed Codex fixture.

## Acceptance evidence and review

The review protocol is in [skills/story/review.md](skills/story/review.md).
The planner lists every claim task in `acceptance.json`, with at least one
handoff criterion per task and a whole-story integration criterion. Criteria
name the required behavior, an executable verification scenario and its expected
outcome. The orchestrator freezes the final approved contract and safe groups
under the protected `.plans/.sessions/` directory before implementation starts.
Changed criteria need renewed approval/freeze; implementers cannot freeze them.

After committing a deliverable, its owner records real commands through
`story-review.sh check`. The record contains HEAD/tree, contract hash, command,
exit code, elapsed time and a hashed output log. Checks run against clean source;
ignored build artifacts are allowed. Checks/evidence from an older revision
cannot certify the new code. A passing command is evidence, not proof that an
arbitrary acceptance criterion was adequately exercised.

The shared foundation is reviewed before dependent tracks consume it. Each
substantive track runs a focused Codex finder when its work is complete, while
other implementation tracks continue. The implementer validates findings and
fixes accepted defects before its completion gate passes. The orchestrator
checks the receipt before accepting `DONE` and stopping that implementer.
Explicitly approved trivial tracks can be `checksOnly`, with passing evidence
and a reason. They do not become unreviewed fallbacks when a tool is missing.

After merging, fresh evidence and the `integrated` review cover the complete
story, including whether the application actually invokes the new behavior.
The repo's plan and PR panels remain explicit policy. The change panel
(`review.changes`) runs on top of the integrated review only when the
orchestrator opts the story in; panels are not copied onto every track. A phase boundary or checkpoint alone does
not trigger a new review. Recorded false-positive dismissals require reasons and
evidence tied to the exact review hash; acceptance gaps cannot be dismissed.

| Setting under `handoffReview` | Default | Meaning |
|---|---|---|
| `model` | Codex configured default | Optional explicit Codex model ID; independent of Claude session routing. Requested settings and raw events are recorded. |
| `effort` | `high` | Explicit reviewer effort, so an inherited `max` is not selected accidentally. |
| `maxRounds` | 2 | Completed reviews per scope/approved contract (initial plus one follow-up), and separately the failed reviewer calls. The orchestrator opens new rounds with `story-review.sh reset <slug> <scope> <reason>`, which is logged. |
| `maxParallel` | 3 | Separate per-story finder cap. A full queue returns exit 3 without consuming an attempt; independent implementation continues. |
| `timeoutSeconds` | 600 | Wall-time bound for each recorded check or Codex run. Timeout stops the subprocess group and never becomes a pass. |
| `maxCheckFailures` | 2 | Repeated failures of the same command on unchanged code stop before another retry; the orchestrator resolves the operational block. |

Follow-up finders focus on the fix delta and previous findings. Exact successful
results are reused only when revision, base, contract, evidence and requested
review settings match. Missing/failed/malformed reviews remain unavailable, not
clean. At the round cap, escalate the evidence to the orchestrator. It resets the
scope with a reason when the fixes converge, or takes a design problem to the
user; never rename a scope or spin an unlimited review/fix loop.

The helper checks record integrity and coverage. It cannot prove that a human or
model's judgment is correct, or make an arbitrary test command meaningful. Its
filesystem sandbox is not a replacement for external-service permissions. The
existing role guard remains a deny list for mistakes, not a hostile-code sandbox.
Record a short story-level lesson when failures reveal a reusable improvement;
detailed retrospectives stay out of normal handoff startup context.

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
tests/story-routing-matrix.sh
```

```bash
python3 tests/story-review.test.py
```

```bash
claude plugin validate .
```

```bash
claude plugin test .
```

The matrix exits 0 when every case passes. Each gate has a case that fails without the gate.

`hooks/story-groups.sh <plan>` prints the tracks of a plan's claims table, as the orchestrator sees them at the plan gate.

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

## Workflow assessment (2026-11-07)

The original design already had fresh worktrees, one writer per file area,
dependency/file-claim checks, per-track scope verification, a small orchestrator,
durable state and whole-story integration/review. These match established patterns.
The gaps were an explicit Opus 5.5/high setting for every handoff, an example cap
of three, instructions to bundle small tasks, and no handoff size/model gate.
Routing, budget preflight and revised planning instructions address those gaps.
They do not establish an optimal concurrency level without measurements.

The default remains sequential when a consuming repo omits `parallel.max`; the
example's new ten-track cap does not migrate other repositories. This plugin
checkout has no `.claude/story.json`, so it is not itself an enabled story project.
At audit time the local user settings selected `opus`; no global effort override
was present in the inspected settings. The clone was listed in
`CLAUDE_CODE_PLUGIN_DIRS` while the marketplace copy was also enabled/registered.
Verify which source Desktop actually loads and keep one installation source;
the configuration alone does not prove duplicate execution. No user settings or
consumer repositories were changed by this audit.

Priorities for further speed/cost work:

- Measure accepted-story elapsed time, spend, rework, peak context and compactions
  across comparable stories with three, five and ten tracks. Use the ledger's new
  fields; account for shared account limits and local test CPU/RAM. Context
  occupancy and cumulative billed tokens measure different things.
- Reduce startup context using `/context`, concise CLAUDE.md, scoped rules and
  selective source retrieval. Repeating a 100k startup ten times can dominate a
  small story; the configured assumption needs measurement.
- The existing protocol documents round barriers (all children idle) and user-turn
  restrictions on new sessions. Prefer one bounded deliverable per track; evaluate
  individual idle notifications against the live Desktop host before replacing
  the scheduler. Model routing cannot remove host scheduling restrictions.
- Keep full acceptance criteria/contracts as authoritative evidence, but avoid
  repeated raw data/tool logs in the orchestrator. Haiku fetches facts; stronger
  models resolve ambiguity. Executing tests needs no advanced reasoning; designing
  regression coverage and diagnosing failures are separate tasks.
- Inspect prompt-cache hit/write rates for long-running subagents before changing
  `subagentPromptCacheTtl`. A one-hour cache can avoid repeated writes after long
  checks, but has different write economics; it is not an unconditional saving.
- Retain the integration owner and final full verification. File-region claims
  are planner assertions; `--scope` verifies paths, not semantic independence or
  the exact edited region. Isolate test ports, databases and generated outputs as
  concurrency grows. Keep external review costs in the same accounting.
- The bundled review panel pins every Codex deep/plan head to `gpt-6.1-sol`
  and rejects other model overrides. Its default single-pass review inherits
  its own Codex configuration; Claude routing does not set Codex model/effort.
  Make reasoning effort explicit in consuming repo commands and reserve
  multi-head deep review for changes that warrant it.

Official sources checked on 2026-11-07:

- [Claude Code cost guidance](https://code.claude.com/docs/en/costs) recommends
  Sonnet for most coding, reserving Opus for difficult reasoning, and isolating
  verbose test/document operations in smaller subagents.
- [Model and effort configuration](https://code.claude.com/docs/en/model-config)
  documents the 5.5 model IDs, medium defaults, effort precedence, context windows
  and the cost/latency tradeoff. The environment can override explicit effort.
- [Subagent configuration](https://code.claude.com/docs/en/sub-agents) documents
  per-invocation model/effort, forced model overrides and separate contexts.
- [Desktop sessions](https://code.claude.com/docs/en/desktop) and
  [cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)
  document parallel worktrees and status/finding exchange.
- [Agent team guidance](https://code.claude.com/docs/en/agent-teams) cautions that
  dependency-heavy and same-file work may favor a single session. These team
  recommendations are not a benchmark of this plugin's Desktop scheduler.
- [Prompt caching](https://code.claude.com/docs/en/prompt-caching) documents cache
  TTL controls and their precedence.
- [Thariq Shihipar, Spending your effort, September 25](https://claude.dev/blog/spending-your-effort/)
  presents first-party experiments: medium for ordinary engineering and higher
  effort where edge cases/verification matter. Its examples are not measurements
  of this repository.

Recent practitioner sources (the requested July–November window):

- [Ryan Klein, August 1; updated August 25](https://ryanklein.dev/notebook/practical-claude-code-use):
  small feature cycles, small context, Opus planning and Sonnet execution.
- [Codex Studio, September 6](https://note.com/codex_studio/n/nd0287e264ffb):
  a practitioner reading of coordination/dependency costs and the need to split
  tasks before choosing worker count; much of it interprets official team docs.
- [MixRoute, November 6](https://mixroute.ai/blog/claude-code-worktrees/): separate
  worktrees per task and deliberate integration. This is a vendor-authored guide.

These reports corroborate the workflow pattern. They are not controlled evidence
that ten sessions are universally faster or that a chosen model always succeeds.
