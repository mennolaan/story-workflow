# Evaluation-driven development

Define the expected behavior and failure cases before changing an agent, skill,
prompt or workflow policy. Add a regression for each observed failure. Separate:

1. Outcome: did the artifact/behavior satisfy the requirement, without invented
   facts, weakened acceptance or false completion?
2. Process: did the appropriate skill/agent run, respect ownership and use the
   requested model/effort? Activation alone earns no outcome credit.
3. Mechanics/integration: do hooks, frozen references, evidence freshness and
   Desktop session coordination actually enforce the intended transitions?

## Native behavioral suite

`evals/*/case.yaml` uses JSON syntax, which is valid YAML 1.1 input for Claude
Code's native eval format. The suite is deliberately inspectable without a YAML
package. Local CLI help and https://code.claude.com/docs/en/plugin-evals were
checked on 2026-11-09. The cases are authored fixtures, not production evidence.
Prompts contain task facts; graders are separate, with explicit pass/fail rules.
The model must not inspect graders. In future datasets, keep private holdouts in
an independently maintained eval package rather than exposing their answers.

Every run uses real account model calls. Nothing runs automatically on install,
at story intake or on a hook. Native evals default to three runs per arm. Their
score is not a statistically established reliability estimate; report sample
count, variance, failures and artifacts. Use a larger repeated set before making
quality/cost claims. Compare proposed routes on the same fixtures, not job titles.

A bounded discovery/outcome smoke comparison:

```bash
claude plugin eval . --case documentation-approved-change --runs 1 --ablation with-without --model sonnet --judge-model sonnet --concurrency 1 --max-cost-usd 3 --keep-temp --no-publish --trust-plugin
```

The trust flag is suitable here because these are our authored local files.
This smoke does not grant shell/write/network tools and exercises no external
board/wiki/PR. Native mocks remain enabled; do not enable real MCP servers for
these fixture cases. Reports stay local. The cost ceiling is checked between
runs, so in-flight work can exceed it. Record actual cost and token/cache usage.

Repeated capability/discovery comparisons:

```bash
claude plugin eval . --tag documentation --tag requirements --runs 3 --ablation with-without --model sonnet --judge-model sonnet --concurrency 1 --max-cost-usd 15 --keep-temp --no-publish --trust-plugin
```

Direct agent and missing-config contract cases use one arm: naming a plugin-only
agent in a without-plugin run would create an artificial baseline failure.
The test-runner/story-reader cases prescribe harmless fixture shell commands;
only these cases need a shell grant. They run in isolated eval workspaces:

```bash
claude plugin eval . --tag agents --tag workflow --runs 3 --ablation none --model sonnet --judge-model sonnet --allow-tools Bash --concurrency 1 --max-cost-usd 15 --keep-temp --no-publish --trust-plugin
```

The large-story plan route cases copy the shipped `/story` skill, the routing
hooks and `story.example.json` into the run's workspace with a `fixture.sh`
scaffold, so the model reads the real rules and runs the real `story-route.sh`.
They need `--scaffold` (our own script, run as you) and a shell grant:

```bash
claude plugin eval . --case 'workflow-*-story-plan-route' --runs 3 --ablation none --model sonnet --judge-model sonnet --allow-tools Bash --scaffold --concurrency 2 --max-cost-usd 5 --keep-temp --no-publish --trust-plugin
```

`--case` takes one glob; a second `--case` replaces the first. Run
`agent-story-reader-story-points` (story points in the digest) with the agents
command above.

They check the decision only: a large story routes the plan to Fable 5.2/medium
and an Opus orchestrator asks before starting it; a normal story stays on
Opus/high. Desktop's `start_session` model cap needs a real `/story` run.

Candidate model selection stays explicit via `--model`; choose the grader model
independently via `--judge-model`. Agent fixtures also set explicit worker model
and effort in their task prompts. Verify actual Agent call inputs/trace; native
case files currently have no documented effort field, so do not invent one.
For parent effort comparisons, use the same controlled CLI environment (for
example CLAUDE_CODE_EFFORT_LEVEL) and record it, noting possible worker overrides.
Do not use a forced global subagent model for mixed-model routing comparisons.

Native threshold scoring can exclude plugin-only activation graders in an
ablation. Inspect those indicators as well as outcome scores; a green threshold
alone is not evidence of discovery. Audit a saved native report with:

```bash
python3 evals/check-results.py evals/results/<run>/aggregate-result.json --require-baseline
```

This refuses partial/error runs, skipped graders, insufficient repetitions and
failed process indicators, even when the CLI's weighted score passes. For an
explicit one-run smoke use `--min-runs 1`; that does not establish reliability.
Omit `--require-baseline` for direct agent-only suites. Keep raw traces with
`--keep-temp` for model/effort and behavior inspection; the report names their
temporary paths. Retain/copy those artifacts before cleanup for a release audit. Read sampled transcripts and calibrate LLM
judges against human labels, especially disagreements. Keep critical violations
(invented approval, lost requirements, unauthorized writes, false passes) as
release blockers even if a weighted average looks good.

`holdout` tags mark cases excluded from routine prompt tuning. Use them only
for candidate promotion; add fresh variants after inspecting a failure. The
small supplied set bootstraps the loop; it is not a private independent benchmark.
No results may be fabricated from a grader rubric or a mocked Codex pass.

## Coverage and mechanical checks

The inventory test fails when an agent or skill is added without a native case.
For the user-only `/story` command, the native fixture checks observed repository
preflight instead of requiring a model-invoked Skill call: its
`disable-model-invocation` setting means that would measure the wrong path.
User-command expansion and positive Desktop orchestration remain host tests.
Other skill cases measure actual Skill activation separately from outcomes:


```bash
python3 tests/eval-suite.test.py
python3 tests/story-review.test.py
bash tests/story-routing-matrix.sh
bash tests/story-hooks-matrix.sh
```

Review tests use real temp Git revisions and stubbed Codex calls to falsify
coverage/provenance invariants. Routing tests cover model/effort overrides and
forced-environment conflicts. Hook tests cover ownership, board retrieval and
checkpoint mechanics. These are complementary to semantic model evals; they do
not establish that the agents choose good requirements or find real defects.

The native workflow cases cover preflight refusal and bounded routing choices.
They do not emulate Claude Desktop's session tools, live compaction, race/resource
behavior or full multi-worktree delivery. For release confidence, also run a
small known story in Desktop: source/refine -> plan/docs -> two safe tracks ->
foundation/handoff reviews -> integrate -> trace -> docket. Record actual model/
effort, artifact hashes, task ownership, stale-evidence rejection, elapsed time,
compactions and token usage. Do not mark host integration passed from text evals.
The existing context-keeper suite separately tests compaction state transitions.

Before promoting a policy/model: run affected deterministic checks, repeated
native outcome/process evals against the previous configuration, held-out cases
and required Desktop integration. Preserve reports and failure transcripts.
No automatic model escalation or unbounded tuning loop. Evals inform the
orchestrator's future selection; they do not assert that Sonnet/Haiku/Opus is
universally adequate or that more concurrent sessions always improve throughput.
