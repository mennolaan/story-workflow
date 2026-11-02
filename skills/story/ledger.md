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

| Name | Id | Role | State | Started (UTC) |
|---|---|---|---|---|

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
