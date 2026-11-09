# Acceptance evidence and handoff review

Use this procedure in every implementation handoff. The built-in finder is a
fresh Codex CLI process with a read-only filesystem sandbox, not another turn of
the implementing conversation. The implementation session judges each finding
against source and check output; only accepted findings are fixed. The
orchestrator checks receipts and routes questions, rather than reading diffs.
The scripts validate provenance and completeness of the records, not the truth
of arbitrary assertions or the adequacy of an arbitrary test command. This is
not a security boundary against a determined writer of scripts.

## Plan and freeze

The planner writes `<plans>/<slug>.d/acceptance.json`. List every claim-table task
exactly once in `tasks`. Give every task at least one handoff criterion scoped to
that task. Add integration criteria for runtime wiring and whole-story behavior.
State a concrete command/scenario and expected outcome in `verification`.

```json
{
  "tasks": ["101", "102"],
  "criteria": [
    {"id":"AC-101","tasks":["101"],"stage":"handoff","requirement":"API contract remains compatible","verification":"run contract tests; existing consumer still parses responses"},
    {"id":"AC-102","tasks":["102"],"stage":"handoff","requirement":"new handler handles empty input","verification":"run the handler regression test; empty input returns the specified result"},
    {"id":"AC-story","tasks":["101","102"],"stage":"integration","requirement":"application actually invokes the new handler","verification":"run the end-to-end request scenario and assert the stored result"}
  ],
  "checksOnly": {}
}
```

For a genuinely trivial task, the orchestrator may add its id and reason to
`checksOnly`, for example `{"102":"copy-only correction; no runtime behavior"}`.
This is a deliberate plan decision, not a fallback for missing review tools.
Only a track whose entire scope is classified this way skips the model call;
it still needs captured checks. Foundation and integrated reviews remain required.

After any scope decisions are incorporated at the plan gate, the orchestrator runs:

```bash
"<plugin>/hooks/story-review.sh" freeze <slug> "<plans>/<slug>.d/acceptance.json" --require-traceability
```

This validates coverage against the safe claims groups, refuses a handoff
criterion whose tasks sit in two safe groups (make it an integration criterion
or split it) and `checksOnly` on a foundation or integrate task, and saves the approved
contract and group membership under the already protected `.plans/.sessions/`.
Only the bound orchestrator can freeze it. A changed source contract invalidates
the approval until the orchestrator approves/freezes it again. Other sessions
read it; they never weaken requirements to satisfy a completion gate.

## Documentation and requirement traceability

New plans use the documentation skill (`../documentation/SKILL.md`) to assess
constraints/impact and own doc updates, followed by requirements refinement
(`../requirements/SKILL.md`). Add `requirements` and `documentation` to the
contract before the strict freeze above. The optional specialist agents are
selected/routed only by the orchestrator; these procedures do not require a
second full review or an additional agent for every story.

```json
{"requirements":[{"id":"R-1","requirement":"Retries do not duplicate work",
 "source":"story #42 AC2","criteria":["AC-101","AC-102","AC-story"]}],
 "documentation":{"reason":"The public retry contract changes","items":[
 {"id":"DOC-1","source":"docs/api.md#retry","action":"update",
  "reason":"Document the approved behavior","criteria":["AC-102"]}]}}
```

Each requirement needs text, source and unique known criterion links. Every
criterion must map to at least one requirement. Documentation has an assessment
reason and `items`; every item needs id/source/action/reason/criteria. Actions
`update` and `verify` require criterion links; `none` has no links and explains
why the checked source needs no change. Empty items are valid only with a
recorded assessment reason. The validator cannot prove extraction completeness
or semantic correctness: the planner/reviewer checks original source coverage.

After the integrated/PR gate, derive a current coverage report with no model call:

```bash
"<plugin>/hooks/story-review.sh" trace <slug> integrated all <original-base-sha> [dismissals.json]
```

Save it as `<slug>.d/traceability.json`. It validates the same revision, frozen
contract, check logs, review result and supported dismissals as `gate`. It emits
requirement/criterion/task/check/review links, documentation obligations and
`TRACE OK`. It refuses stale/missing evidence, partial-track scopes, acceptance
gaps and unresolved blocking findings. After any fix, recapture/review and
regenerate the report. The orchestrator verifies it before completion.

Existing contracts without either new section still work with the old freeze
form, but trace returns `TRACE LEGACY`, never invented modern coverage. New
stories use `--require-traceability`, which refuses missing sections. Migrate a
running legacy story only through the orchestrator's explicit source/coverage
reassessment and re-freeze; never delete sections to pass a gate.

## Capture checks

Commit the deliverable first. Source must be clean before and after each command;
normal ignored build/test artifacts are fine. `.plans/` must be gitignored.
Run the real verification command through the recorder in the owned worktree:

```bash
"<plugin>/hooks/story-review.sh" check <slug> track-A AC-102 -- npm test -- --runInBand
```

Arguments after `--` are an argument array, not an evaluated shell string. For a
pipeline use an explicit shell, for example `-- bash -o pipefail -c '<pipeline>'`.
One command may cover several criterion ids separated by commas, when its actual
checks establish all of them. A test suite exit code alone does not demonstrate
runtime wiring, database state or a browser interaction unless it tests them.
Never attach an id merely because a command passed. Capture those scenarios too.

Keep secrets out of the argument array. The shell expands `$API_TOKEN` before
the recorder sees it, so pass it unexpanded inside single quotes:
`-- bash -c 'curl -H "Authorization: Bearer $API_TOKEN" …'`. The recorder also
redacts values of environment variables named like a token, key, secret or
password, bearer/basic values, `token=`/`password=` values and URL passwords from
the stored command; the command itself runs unredacted. Output is not redacted,
and the reviewer can read the check logs: a check must not print secrets.

The recorder saves command, exit code, elapsed time, output, contract hash, HEAD
and tree. Failed/timed-out checks are recorded as failures. Newer evidence for a
criterion replaces older evidence at the same revision, allowing recovery from
an environment failure. Repeated failures of the same command on unchanged code
stop after `handoffReview.maxCheckFailures` (default 2): return `BLOCKED` with the
evidence and ask the orchestrator to resolve the cause, rather than retrying.

## Review, judge, gate

Scope names are `foundation`, `track-<safe group name>`, `integrated` and `pr`.
Track/foundation task ids must match the frozen safe group exactly. Integrated
and PR scopes use `all`. The base is the original immutable base sha of that
scope, not a moving branch name in the saved review identity.

```bash
"<plugin>/hooks/story-review.sh" run <slug> track-A 102 <base-sha>
"<plugin>/hooks/story-review.sh" gate <slug> track-A 102 <base-sha>
```

`run` returns `REVIEW READY`, findings, per-criterion assessments and artifact
paths. This is not approval. Validate findings against source and reproduce
failures when useful. Accepted blocking findings go to the owning implementer
for a fix and fresh checks. Re-run against the same original base. The next
finder focuses on changes since the previous reviewed head and the earlier
findings, with the complete frozen contract still available.

A false positive may be dismissed with a concrete reason and evidence, never
just "intentional" or "tests pass". Pass this JSON file as the final argument of
`gate` (it must name the returned result hash):

```json
{"reviewHash":"<resultHash>","dismissed":[{"id":"F1","reason":"the alleged missing authorization already executes before dispatch","evidence":"src/router.ts:42 and the unauthorized-request regression test"}]}
```

Keep that decision with the scope artifacts and in the status report. Dismissal
is a reviewer's judgment, not a mechanically proven fact. An acceptance `gap` or
`unverified` assessment cannot be dismissed by this mechanism. Resolve it with
actual implementation/evidence and another review, or raise a real scope decision.

`gate` returns `REVIEW OK` only for the exact current code, frozen contract,
scoped task ids and passing evidence, with no unresolved blocking findings or
acceptance gaps. A trivial approved track returns `CHECKS ONLY`. Record the
receipt path/hash and both initial/final findings in the track status.

## Keep work parallel and review bounded

Each completed substantive track starts its own finder before sending `DONE`,
while other implementers continue. Review slots are separate from the track cap.
The per-story default is three simultaneous finders. A full queue returns exit 3
and `REVIEW QUEUED` without consuming an attempt. End the turn with `BLOCKED`,
identify the queue, and retain the implementing session. The orchestrator sends
`next: review` when capacity is available; it does not pause unrelated tracks or
ask the user to approve an ordinary review.

Default limits: two completed reviews per scope/approved contract, two failed
reviewer calls, ten minutes per check or review, and two repeated check failures.
A failed, malformed, timed-out or interrupted call never counts as a clean review
and does not use a round; it counts toward the failed-call limit. At `REVIEW LIMIT`,
stop and send the unresolved findings and evidence to the orchestrator. Do not
start a renamed scope or change the contract to evade the limit.

The orchestrator decides what happens next. When the fix cycle converges (the
open findings are new defects of the fixes, not a design problem), it opens new
rounds for that scope with a logged reason:

```bash
"<plugin>/hooks/story-review.sh" reset <slug> integrated "second docket fix; the findings converge"
```

`reset` is orchestrator-only, needs a nonempty reason and appends it to the
scope's receipt. Record it in the ledger. When the findings point at the design,
take that to the user instead of resetting. A stopped or killed recorder stops
its reviewer process; a reviewer left running by a killed recorder is stopped
before the next attempt of that scope.

An identical successful finder result is reused when code, base, contract and
captured evidence match. Failed calls can be retried within the cap. Changed
source/evidence requires a fresh review; old approval cannot be replayed.
Events and usage returned by Codex remain in each run's `events.jsonl`; missing
usage stays unavailable. The reviewer inherits normal Codex configuration and
credentials, with explicit effort (`high` by default) and optional configured
model. Its filesystem sandbox does not replace external-service permissions.

After tracks are accepted, the story branch captures fresh evidence and runs
the `integrated` scope with `all`, including the integration scenarios. This is
the whole-story acceptance/interactions review and the default final review.
The repo's plan and PR panels stay repo policy. Its change panel
(`review.changes`) runs on the same commits only when the orchestrator opts the
story in (security, personal-data or cost surface), so one change does not get
two full Codex reviews. Never run a panel on every track. Keep cost/rounds in the ledger.
Do not automatically run more finders because a pass was clean.

At story close, record only reusable, evidence-backed lessons: repeated false
positives, missing acceptance coverage or retry/context waste. Keep a short link
in the ledger. Detailed retrospectives load on demand, not in every handoff.
