# Refinement and evaluation research

Checked 2026-11-09. Recent articles below are within the requested four-month
window (since 2026-07-09). Current living documentation/templates have no
verified publication date: they are clearly identified as current references,
not presented as dated practitioner experiments. No source establishes that our
plugin's routing, ten sessions or any specific refinement template is optimal.

- Adroit, “The Story Is Too Big,” 2026-09-11:
  https://adroit.io/field-notes/backlog-refinement-story-slicing-2026
  Its worked publishing example starts from a content-manager request, discovers
  editorial/legal/staging steps and recommends a small end-to-end first slice.
  Useful for separating product value from technical tasks and stopping refinement
  when consequential uncertainty is resolved. This is practitioner guidance, not
  a controlled benchmark or an original PO-to-merged-code audit trail.
- BMad, current official “Break Work into Stories and Track It”:
  https://docs.bmad-method.org/plan/break-work-into-stories-and-track-it/
  Demonstrates a PO-led path from intent/PRD to requirements, story coverage,
  dependencies, verification and build plans. We borrow explicit unknowns and
  coverage, not its whole orchestration/persona system. Publication date unverified.
- GitHub Spec Kit, current official specification and task templates:
  https://github.com/github/spec-kit/blob/main/templates/spec-template.md
  https://github.com/github/spec-kit/blob/main/templates/tasks-template.md
  Prioritized user journeys include independent tests and acceptance scenarios;
  the task template separates foundation and parallel opportunities. These are
  templates, not evidence of production outcomes or validated story sizing.
- Expo/Georgian, “Your skills need an evaluation mechanism,” 2026-10-08:
  https://expo.dev/blog/your-skills-need-an-evaluation-mechanism
  Measures discovery/activation separately from instruction uptake and delivered
  app behavior. Its task set is Expo-specific; its reported improvements do not
  predict our workflow's performance. We adopt baseline comparisons and separate
  process/outcome grading, not its numerical results as our own.
- Claude Code, current official plugin eval documentation:
  https://code.claude.com/docs/en/plugin-evals
  Defines native cases, graders, baseline arms, repetitions and bounded runs.
  Checked against local `claude plugin eval --help`. Native evals exercise actual
  model behavior; stubbed CLI/hook tests cannot establish semantic agent quality.

The local worked cancellation example is synthetic and explicitly supplies its
PO decisions. Its unresolved variant is a negative eval: guessing those answers
must fail. Public material found provides useful examples/templates, but not a
verified recent dataset pairing original PO tickets, refinements and downstream
outcomes. We do not invent that evidence. Production failures should become
anonymized held-out regression cases as they occur.
