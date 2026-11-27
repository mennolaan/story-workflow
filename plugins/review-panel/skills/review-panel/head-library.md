# Head library (deep mode)

Read by the review-panel procedure (`SKILL.md` beside this file) in deep mode and for a plan review, before choosing heads.

`heads/_focus.md` is the default review focus (the delivery, dependency,
identity, conformance and situate stances in one Codex review; the absence
class enters default mode only through the scope exception, so parity
coverage needs deep). `heads/*.md` are the stance heads for deep mode,
rendered behind `heads/_preamble.md` by `run-heads.sh`: attack `delivery`,
`dependency`, `identity` (identity, redaction and gates), `reach` (who can
start the code and what it holds while it runs), `falsify` (for each check,
the mutation it still passes); absence `parity` (names the sibling that sets
the precedent); situate `situate` (names its source); conform `conform`
(cites its authority, no failure scenario); library-only `daytwo` (rotation,
re-run, purge), `invariants` (the project invariants of the profile context
and the couplings around them) and `ux` (the page, the PDF and the deck
against the story's design boards: missing states, copy that differs in
meaning, numbers and legends shown differently, controls a keyboard or
screen-reader user cannot reach). The deep default is delivery, dependency,
identity, parity, situate, reach, falsify (`deepHeads` changes it); conform,
daytwo, invariants and ux are selected explicitly: conform in every plan
review, where there is no code to compare against a sibling; daytwo when the
diff carries rotation, re-run or purge procedures; invariants when the change
touches an invariant the profile context names; ux when the story attaches a
design and the diff renders it, after the orchestrator unpacks the boards into
the scratchpad and lists their paths in `facts.md` under "UI reference
material" (a head reads no zip, so the unpacking happens before the run).
A profile head file `heads/<head>.md` is appended to the generic head of that
name as project detail (the sibling folders to read, the store that counts as
durable), or is a head of its own when the plugin has none.
A new head is admitted only when external review or an escaped defect shows
a class no existing stance covers. `ux` was admitted that way: in three
panels on one story it raised three design departures that no attack or
absence head raised.
Edit the prompt file, never the rendered copy in the scope dir. The
preamble behind every head separates reading from reporting: a head reads
anywhere in the repo and reports only against the scope file list.
