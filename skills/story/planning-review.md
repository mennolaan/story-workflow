# Optional planning specialists

The orchestrator decides whether either specialist is worth its startup/context
cost. These are read-only subagents of the orchestrator, not additional Desktop
handoff sessions or implementation tracks. They do not bind a session, write
shared state, replace the planner, or replace configured plan/Codex reviews.
Their selection and completion gate below is procedural; `story-route.sh`
validates launch settings, not the semantic completeness of their reviews.

## Selection and timing

At story intake, assess the roles below from the story-reader digest, existing scope
decisions and available evidence. Record `run`, `skip` or `defer until draft`,
with a concrete reason, in the ledger. Missing source facts go to source-reader
first; a specialist is for a decision/review question, not fetching documents.

- **Requirements reviewer:** run for ambiguous user outcomes, conflicting
  business rules, missing failure/recovery behavior, untestable criteria or
  consequential assumptions. For a clear, routine story, skip with a reason.
  It may run before planning when ambiguity would waste planning work, or on the
  first draft when acceptance coverage is the question.
- **Architect reviewer:** normally defer until the first draft. Run for
  unresolved cross-system contracts, data ownership, migrations, security or
  concurrency boundaries, or uncertainty about track independence. Skip when
  existing contracts/patterns and ownership are clear. Complexity alone is not
  a reason for a second agent to repeat the planner's full investigation.
- **Documentation reviewer:** optional for substantial plan/document comparisons
  or unresolved authority/drift questions. Routine assessment stays with the
  existing planner. The documentation skill's impact check is required even
  when this agent is skipped. At completion, the orchestrator may scope a fresh
  documentation or requirements evidence recheck; routine trace derivation
  reuses the existing integrated review without another agent.

On the planner's draft `PHASE DONE`, reassess the roles before sending `next:`
for the plan's Review phase. Resolve deferred decisions to `run` or `skip`.
When selected reviewers can inspect the same snapshot independently, invoke them in parallel.
When an unresolved product decision determines architecture, settle that first
and then supply the revised snapshot to the architect. Do not serialize
unrelated source reads or implementation tracks behind an unnecessary review.

## Choose model and effort per invocation

Use the cheapest adequate profile and explicit effort for the bounded question:

| Work | Starting route | Escalation reason |
|---|---|---|
| Requirements/acceptance gaps | `requirements` (Sonnet/medium) | conflicting rules or consequential ambiguity needs deeper reasoning |
| Documentation impact/drift | `documentation` (Sonnet/medium) | a consequential ambiguity warrants review/high or complex/high |
| Architecture within established patterns | `review` (Sonnet/high) | unresolved design with security, concurrency, migration or broad contract risk |
| Difficult unresolved requirements/design | `complex` (Opus/high) | name the specific reasoning problem; no default xhigh/max |

These are starting points, not mandatory tiers. The orchestrator may choose a
different known profile or effort for a justified question; fetching facts and
running prescribed tests still belong to the existing cheap workers. Profiles
and provider model IDs respect the repo's `routing` overrides.

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/story-route.sh" requirements-review --profile requirements --effort medium
"${CLAUDE_PLUGIN_ROOT}/hooks/story-route.sh" architect-review --profile complex --effort high
```

Use the route's `model` and `effort` explicitly on the Agent call, with type
`story-workflow:requirements-reviewer` or `story-workflow:architect-reviewer`.
Documentation uses `story-route.sh documentation-review` and
`story-workflow:documentation-reviewer`; optional final requirements interpretation
uses `story-route.sh requirements-verify` and the existing requirements reviewer.
Use its family alias only when the live Agent schema requires aliases; check
that the alias resolves to the intended model/provider configuration. If the
host cannot express the route, resolve the mismatch before launching. A model
sentence in a prompt is not configuration. Verify requested versus observed
model/effort when the host exposes them; otherwise record `unverified`.
The resolver checks shell effort/forced-model conflicts; also check the
effective Desktop/managed settings and mod overrides. A forced-model setting
without an explicit model cannot be verified by this resolver alone.

Routes without task estimates include startup only. Do not report this number
as the specialist's measured total context or as a spend prediction. Bound the
input scope and output; record actual usage/elapsed time when exposed.

## Snapshot and output

The orchestrator writes a numbered input snapshot under
`<slug>.d/planning-reviews/<role>-<n>-input.md` and saves the returned report in
`<role>-<n>-report.md`. Include:

- A snapshot id, the exact review question and relevant task/criterion ids.
- The authoritative story digest, user scope decisions, cited source evidence
  and explicit unknowns. Preserve acceptance text in full, not an agent's
  paraphrase of it. Link large stable material by absolute path.
- Absolute paths and content hashes (`shasum -a 256`) for reviewed plan,
  acceptance and supplied evidence files. For code inspection include the
  checkout path and HEAD, and identify any uncommitted source changes.
- The selected profile/model/effort, bounded scope and requested output format
  from the agent definition. No raw conversation history or unrelated backlog.

Do not let the planner change snapshot files while a review reads them. Copy the
relevant draft/evidence into the input folder or hold draft edits until the
bounded pass returns. Both reviewers may read the same immutable snapshot.
Missing evidence produces an incomplete review, not a clean result.

## Reconcile before acceptance freeze

Forward planning reports to the planner (completion reports to the owning
implementer). That owner validates findings against source evidence,
records each finding as accepted/rejected/deferred with a reason, and revises
the plan, claims, routing and acceptance scenarios together. Reviewers cannot
add requirements or overrule the user. The planner sends genuine product/design
decisions to the orchestrator, which resolves them from existing authority or
asks the user only when necessary. Consolidate related questions.

The planner includes `## Planning specialist review` in the plan: each role's
run/skip reason, snapshot/report paths, coverage limits, findings/dispositions,
and unresolved decisions. At `PLAN READY`, the orchestrator checks this summary
against its ledger. No deferred selection or unresolved blocking finding may
silently pass the plan gate. A missing/failed required review must be completed
or explicitly reassessed by the orchestrator with evidence; never label it pass.

One initial pass per selected role and lifecycle stage (planning or final
verification), with at most one focused follow-up when
necessary to verify an accepted correction. An incomplete pass consumes a pass;
do not loop on missing sources, tools or credentials. After that, the
orchestrator resolves the cause or records why a newly scoped review is needed.
No automatic agent-to-agent debate. Findings are scoped to their snapshot:
material requirement/contract/ownership changes invalidate affected conclusions
and require reassessment; unrelated edits do not rerun every specialist.

After reconciliation, the planner runs the configured plan review on the final
proposal, then reruns `story-groups.sh` and `story-route.sh --check`. Changes from
that review also need specialist reassessment if they affect reviewed decisions.
The orchestrator freezes acceptance only after these steps. During
implementation, reopen only the affected planning decision when a new risk
appears, keep independent safe tracks running, and renew the frozen contract if
requirements change. Existing per-handoff and integrated Codex gates still run.
