# Context rule: the mechanics

How the hooks and the context-keeper mod carry out the context rule of `/story` (`SKILL.md` beside this file). Read it when a checkpoint, a compaction or a resume does not behave as expected.

Steps 1, 2, 4, 5 and 7 run only on a context window of 400k tokens or more. The original setup measured startup near 100k tokens; at that size a 200K window cannot compact below the save point. Measure startup for the consuming repo rather than assuming this overhead for every session.

1. **Nudge.** `context-guard.sh` (PostToolUse) adds one note per crossing: run `/checkpoint` at the next safe moment.
2. **Gate.** The same script (Stop) blocks the end of the turn once while the checkpoint is stale.
3. **Save.** `/checkpoint` writes the state file and ends with `CHECKPOINT-READY: <path> | continue` (or `| wait`).
4. **Compact.** The context-keeper mod (`hooks/register.tsx` of this plugin) compacts at the turn boundary once the checkpoint is fresh. With a stale checkpoint it runs `/checkpoint` once, then shows a toast. A checkpoint is stale too when more than 3 main turns ended after its last write (a turn kept the compaction from running). Then the mod runs `/checkpoint` again, once, and compacts at a later turn end, after the new write.
5. **Steer.** The mod adds the role and the state path to the instructions of every compaction.
6. **Re-prime.** `session-reprime.sh` (SessionStart `startup|clear|compact`) prints the role card, the paths and the saved state of a bound session.
7. **Resume.** After a `continue` checkpoint the mod sends `Continue from <path>: next action <...>`, 3 seconds after the compaction ends. Not after `wait`, a turn that starts after the compaction (a background notice starts one), an aborted turn, a draft in the prompt box, a prompt from the person or the host, a checkpoint written after the compaction, or a checkpoint more than 3 turns behind when the compaction runs (a queued `/compact`; the mod logs it). A turn that started before the compaction ended and runs at that time moves the check to its end.
8. **Backstop.** Without the mod, auto-compaction runs at about 400k tokens (40% of a 1M window), with the state already saved by steps 1 to 3. Claude Code compacts about 32k tokens below `autoCompactWindow` (E0 on 2026-10-27: 92% of 400000, about 368k; the reserve is inferred from two data points), so `autoCompactWindow` and `backstopTokens` are 432000.
