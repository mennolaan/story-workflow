# Ledger {{SLUG}}

The orchestrator is the only writer. Newest entries first in each section.

## Story

- Work item: #{{STORY_ID}} {{STORY_TITLE}}
- Tasks: {{TASKS}}
- Branch: {{BRANCH}}
- Plan: {{PLANS}}/{{SLUG}}.md

## Phase

plan | plan gate | implement | tracks | merge | docket | push | pr-review | done

Mode: sequential | parallel (the user's words at the gate)

## Linked sessions

| Name | Id | Role | State | Model | Effort | Reason | Estimated context / target | Started (UTC) |
|---|---|---|---|---|---|---|---|---|

Record requested and observed model/effort separately when they differ. Include
the routing manifest path and any environment or host override. Never mark a
requested setting as verified from the brief alone.

## Routing and usage

- Manifest: {{PLANS}}/{{SLUG}}.d/routing.json
- Before each start: route JSON, selected profile(s), reason and escalation trigger.
- Sizing decisions: independent work split into additional parallel handoffs, or
  reason coupled work stays together. Compare startup/coordination costs with
  expected compaction and rereading overhead. A sizing warning is advisory.
- At completion: elapsed time, peak context, billed input/output/cache tokens when
  available, compactions, retries and accepted result. Write `unavailable` for
  metrics the host does not expose. Peak context is not cumulative token spend.
- Escalations: session/task, failure evidence, old and new model/effort, remaining
  scope. Escalate once after a reproducible capability failure; do not repeat the
  same failing attempt or escalate a missing credential/dependency.

## Acceptance and review

- Frozen contract path/hash; original review base sha.
- Each foundation/track/integrated scope: task ids, reviewed head/tree, check
  records, initial/final findings, judge dismissals with reasons/evidence, receipt.
- Queue/limits: running finder count, queued scopes and retry-only next action;
  stop cause at the round/check limit. Never hide a missing/failed review as pass.
- Criteria still unverified, including browser/database proof.
- Lessons worth retaining: observed failure, cause and one concrete improvement;
  link to detail rather than loading every session's retrospective.

## Planning specialists

The orchestrator owns selection and launch settings; the planner owns finding
dispositions in `## Planning specialist review` of the plan. These are optional
read-only subagents, not extra track sessions. See `planning-review.md`.

| Role | Intake decision and reason | Draft decision and reason | Profile / requested model / effort | Observed model / effort | Snapshot / report | Passes / state |
|---|---|---|---|---|---|---|
| requirements-reviewer | run / skip / defer | run / skip | | | | |
| architect-reviewer | run / skip / defer | run / skip | | | | |

- Record the exact question, task/criterion ids, input hashes and code revision.
- Record elapsed time/usage when exposed; otherwise `unavailable`. One initial
  pass and at most one focused correction check; further scope needs a recorded
  orchestrator decision, not an automatic loop.
- Link finding dispositions and user decisions; resolve incomplete required
  reviews and blocking findings before acceptance freeze. Material scope or
  contract changes require reassessment of affected conclusions.

## Tracks

Parallel mode only. One row per `TRACK` line of `story-groups.sh`, in its order, which is the merge order. Base sha: <the sha the track branches start from>

| Track | Tasks | Branch | Session (name, id) | State | Last sha |
|---|---|---|---|---|---|

## Decisions (the user's own words)

- <UTC> "<quote>" (question: <what was asked>)

## Open questions

- <UTC> <question>, asked by <role>, waits on <orchestrator or user>

## Interventions

Each time the user had to act for a reason other than a real decision (a compaction, a lost message, a stuck session).

## Next action

<one line>
