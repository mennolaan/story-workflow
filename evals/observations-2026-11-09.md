# Observed evals: 2026-11-09

Local Claude Code 2.1.312, requested main/judge model `sonnet`; explicit worker
model/effort checked in Agent call inputs. This establishes requested settings,
not every provider/managed override or a universal model-quality ranking.

## Actual runs

| Run | Candidate cases passing CLI threshold | Notes |
|---|---|---|
| Initial discovery comparison | 1/1 | single trial per arm/case; with/without comparison |
| Initial behavioral smoke | 9/15 | single trial per arm/case |
| First candidate smoke | 12/15 | single trial per arm/case |
| Refinement/verification regression rerun | 4/4 | single trial per arm/case |
| Documentation agent rubric calibration rerun | 1/1 | single trial per arm/case |
| User-command preflight process rerun | 1/1 | single trial per arm/case |
| Fresh promotion cases | 2/2 | single trial per arm/case; with/without comparison |

CLI list-price cost estimate across these runs: **$3.10**. There were
**42 top-level task trials**, including baselines and targeted reruns,
plus judge votes and delegated agent calls. This is a CLI estimate, not a
subscription invoice or a measured token-saving claim.

## What changed because of evidence

- Skill discovery initially failed on several natural requests. Descriptions now
  explicitly cover direct/small tasks; an existing owner can load a procedure
  without spawning another agent. The inspected cases became regressions.
- Refinement now explicitly preserves supplied state names, settled quantifiers
  and downstream behavior outside the change scope. Parallelism is provisional
  until repository ownership/contracts are checked.
- Documentation findings must name a correction and a known owner, or flag
  missing ownership. A rubric that implicitly demanded a named owner despite no
  owner being supplied was calibrated; the agent must not invent that fact.
- The user-only /story command uses an observed preflight process check instead
  of a model-invoked Skill indicator. Native text evals do not exercise the
  Desktop user-command parser or successful multi-session orchestration.
- The result auditor checks unscored candidate process indicators as well as
  outcomes. A failing baseline is valid comparative evidence, not a release
  failure, provided that baseline run/grading completed.

## Interpretation and limits

Latest targeted checks passed, and both newly authored promotion cases passed
in the candidate arm. The documentation promotion case also passed without
the plugin; the export-refinement baseline failed its outcome rubric. This is
one observation per case/arm with an LLM judge, not proof of a reliable advantage.
The iterations changed instructions and some process/grading definitions, so
the table is a development log rather than a controlled before/after benchmark.

The original discovery smoke passed both arms (no observed outcome delta).
The suite now has 17 public synthetic cases; public holdouts are not an
independent private benchmark. Run repeated trials, calibrate judges with human
labels and add anonymized real failure cases before claiming reliability.

Mechanical checks passed: 40 revision/evidence/traceability tests, 8 eval-inventory/
result-audit tests, 65 routing checks, 1304 hook checks, ShellCheck and plugin
validation (existing icon/local .DS_Store warnings). Codex calls in evidence
unit tests are stubbed. Actual Desktop integration remains untested here.

Raw native reports are local under `evals/results/` (gitignored). The reruns
kept raw traces at the paths their reports name; retained fixture directories
are sealed by the native runner. Inspect data only; do not execute their config.
Reports include prompts/rubrics and per-grader results. Retain them for a release
audit before cleaning temporary files. Do not infer an eval passed from this
summary alone; use `check-results.py` and inspect representative transcripts.
