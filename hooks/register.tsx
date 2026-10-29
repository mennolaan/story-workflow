import type { EngineInterface, Register } from 'claude-code'

// The compact half of the context rule (skills/story/SKILL.md of this plugin,
// "Context rule"). context-guard.sh nudges and gates the save; this module
// compacts once the checkpoint is fresh and resumes from it. The rule runs on
// the percent of the model window (context.percent against checkpointPercent).
// The status line and the toast show what the desktop composer shows: the
// percent of autoCompactWindow, plus the save point on that scale. Both read
// .claude/story.json and <plans>/.sessions/<key>.crossed, from the main
// checkout root, because a desktop worktree session runs its hooks there.
// Without .claude/story.json the repo has not opted in: no status line, no
// file write, no compaction and no steer.

type $ = EngineInterface

type Binding = { role: string; slug: string; parent?: string }

type Where = {
  plans: string
  key: string
  binding?: Binding
  state: string
}

const CONFIG = '.claude/story.json'
const DEFAULT_PERCENT = 35
const MIN_CHARS = 400
// A story session starts near 100k tokens (system prompt, CLAUDE.md, skills). Under this
// window the save point sits below what a compaction reaches, so the rule would compact every turn.
const MIN_WINDOW = 400_000
const RETRIES = 40
const RETRY_MS = 500
// A repo path can hold spaces, so a path group is never \S+.
const SENTINEL = /^CHECKPOINT-READY:\s*(.+?)\s*\|\s*(continue|wait)\s*$/

const clean = (s: string | undefined) => (s ?? '').replace(/[^A-Za-z0-9._-]/g, '')

const mem: {
  promptedFor?: number
  toastedFor?: number
  isBusy: boolean
  isCompacting: boolean
  personPromptAt: number
  logPath?: string
} = { isBusy: false, isCompacting: false, personPromptAt: 0 }

const readText = async ($: $, path: string) =>
  (await $.fs.exists(path)) ? await $.fs.read(path) : undefined

/** Appends one line with the time to <plans>/.sessions/<key>.log. A headless host shows no toast, so the log is the record of every refused, skipped or failed step. */
const log = async ($: $, line: string) => {
  const path = mem.logPath
  if (path === undefined) {
    $.ui.toast(`context-keeper: ${line}`)
    return
  }
  const prev = (await readText($, path)) ?? ''
  await $.fs.write(path, `${prev}${new Date(await $.clock.now()).toISOString()} ${line}\n`)
}

const fail = async ($: $, line: string) => {
  $.ui.toast(`context-keeper: ${line}`)
  if (mem.logPath !== undefined) await log($, line)
}

const readJson = async <T,>($: $, path: string): Promise<T | undefined> => {
  const text = await readText($, path)
  if (text === undefined) return undefined
  try {
    return JSON.parse(text) as T
  } catch (err) {
    await fail($, `${path} is not valid JSON, so it is ignored: ${String(err)}`)
    return undefined
  }
}

/** The main checkout root: the parent of the git common dir, the same for every worktree. Without a git dir, the cwd. */
const mainRoot = async ($: $, cwd: string) => {
  const git = `${cwd}/.git`
  if (await $.fs.exists(git)) {
    const stat = await $.fs.stat(git)
    if (stat.kind === 'dir') return cwd
    const link = /^gitdir:\s*(\/.+?)\/\.git\/worktrees\//m.exec(await $.fs.read(git))
    if (link) return link[1]
  }
  return cwd
}

type Config = { checkpointPercent?: number }

/** The repo's .claude/story.json, from the main checkout. undefined: the repo has not opted in. */
const readConfig = async ($: $): Promise<Config | undefined> => {
  const path = `${await mainRoot($, await $.session.cwd())}/${CONFIG}`
  if (!(await $.fs.exists(path))) return undefined
  return (await readJson<Config>($, path)) ?? {}
}

const where = async ($: $): Promise<Where> => {
  const cwd = await $.session.cwd()
  const plans = `${await mainRoot($, cwd)}/.plans`
  const host = clean(await $.env.get('CLAUDE_CODE_HOST_SESSION_ID'))
  const sid = clean(await $.session.id())
  const key = host || sid
  mem.logPath = `${plans}/.sessions/${key}.log`
  for (const k of [host, sid]) {
    if (k === '') continue
    const binding = await readJson<Binding>($, `${plans}/.sessions/${k}.json`)
    if (binding?.role && binding.slug) {
      mem.logPath = `${plans}/.sessions/${k}.log`
      return { plans, key: k, binding, state: `${plans}/${binding.slug}.d/${binding.role}.md` }
    }
  }
  return { plans, key, state: `${plans}/.sessions/${key}.md` }
}

const card = (w: Where) => {
  const b = w.binding
  if (!b) return 'This session is not bound to a story.'
  const parent = b.parent ? ` Its orchestrator is ${b.parent}.` : ''
  return b.role === 'orchestrator'
    ? `This session is the ORCHESTRATOR of story ${b.slug}. It alone asks the user and acts outward.`
    : `This session is the ${b.role.toUpperCase()} session of story ${b.slug}. It never asks the user and never acts outward.${parent}`
}

const instructions = (w: Where) =>
  [
    card(w),
    `The saved state is ${w.state}. Name that path in the summary and say to read it first.`,
    'Keep the role, the story, the decisions in the user\'s own words, the open questions and the next action.',
    'Drop tool output and file dumps.',
  ].join('\n')

const percentOf = async ($: $) => {
  const { context } = await $.session.usage()
  if (context.percent !== undefined) return context.percent
  return context.tokens === undefined ? 0 : Math.floor((context.tokens * 100) / context.window)
}

/** What the desktop composer and /context show: the percent of rawMaxTokens (autoCompactWindow), not of the model window. The rule itself stays on context.percent. */
const shownOf = async ($: $, limit: number) => {
  const { context } = await $.session.usage({ breakdown: 'summary' })
  const raw = context.breakdown?.rawMaxTokens ?? context.window
  const tokens = context.tokens ?? ((context.percent ?? 0) * context.window) / 100
  return { shown: Math.floor((tokens * 100) / raw), save: Math.floor((context.window * limit) / raw) }
}

const isFresh = async ($: $, path: string, crossed: number) => {
  if (!(await $.fs.exists(path))) return false
  const stat = await $.fs.stat(path)
  if (stat.size < MIN_CHARS) return false
  return Math.floor(stat.mtimeMs / 1000) >= crossed
}

const sentinel = (text: string) => {
  const lines = text.trimEnd().split('\n')
  const m = SENTINEL.exec(lines[lines.length - 1] ?? '')
  return m ? { path: m[1], mode: m[2] as 'continue' | 'wait' } : undefined
}

const nextAction = (text: string) => {
  const lines = text.split('\n')
  const at = lines.findIndex(l => /^#+\s*Next action/i.test(l))
  if (at < 0) return undefined
  return lines.slice(at + 1).find(l => l.trim() !== '' && !l.startsWith('CHECKPOINT-READY'))?.trim()
}

const hasDraft = async ($: $) => (await $.prompt.read()).text.trim() !== ''

const crossedFile = (w: Where) => `${w.plans}/.sessions/${w.key}.crossed`

const readCrossed = async ($: $, w: Where) => {
  const n = Number.parseInt((await readText($, crossedFile(w)))?.trim() ?? '', 10)
  return Number.isFinite(n) ? n : undefined
}

const statusLine = ($: $, w: Where, shown: number, save: number) =>
  $.ui.status(`ctx ${shown}% · save ${save}%${w.binding ? ` · ${w.binding.role}` : ''}`)

const resume = async ($: $, w: Where, since: number) => {
  const text = await readText($, w.state)
  if (text === undefined) return
  const mark = sentinel(text)
  if (mark === undefined) {
    await fail($, `the last line of ${w.state} is not a CHECKPOINT-READY sentinel, so the session does not resume. Expected: CHECKPOINT-READY: <path> | continue`)
    return
  }
  if (mark.mode !== 'continue') return
  if (mem.personPromptAt >= since || (await hasDraft($))) return
  const step = nextAction(text) ?? 'see the Next action section'
  try {
    await $.prompt.submit({ text: `Continue from ${w.state}: next action ${step}` })
  } catch (err) {
    await fail($, `the resume prompt was refused, so the session waits: ${String(err)}`)
  }
}

// A headless host (the desktop app runs every session through the SDK)
// refuses $.session.compact for good, but runs /compact between turns. /compact fires
// the session.compact hook below, which adds the steer, so it gets no instructions here.
const compactNow = async ($: $, w: Where): Promise<{ skip?: string }> => {
  if ((await $.session.surfaces()).length === 0) {
    await $.command.run({ command: 'compact' })
    return {}
  }
  return $.session.compact({ instructions: instructions(w) })
}

const SAME_REFUSALS = 3

// A refusal that repeats its own text SAME_REFUSALS times in a row cannot change
// (the headless refusal of $.session.compact does that), so it stops the retries.
const tryCompact = async ($: $, w: Where, since: number, tries: number, last = '', repeats = 0): Promise<void> => {
  const retry = async (why: string, refusal: string) => {
    const count = refusal === '' ? 0 : refusal === last ? repeats + 1 : 1
    if (tries + 1 < RETRIES && count < SAME_REFUSALS) {
      $.clock.after(RETRY_MS, () => void tryCompact($, w, since, tries + 1, refusal, count))
      return
    }
    mem.isCompacting = false
    await fail($, `compaction did not start after ${tries + 1} tries, so the backstop compacts later: ${why}`)
  }
  if (mem.isBusy) return retry('a turn is running', '')
  let done
  try {
    done = await compactNow($, w)
  } catch (err) {
    return retry(String(err), String(err))
  }
  mem.isCompacting = false
  if (done.skip !== undefined) {
    await fail($, `compaction skipped: ${done.skip}`)
    return
  }
  await $.fs.write(crossedFile(w), '')
  mem.promptedFor = undefined
  mem.toastedFor = undefined
  await resume($, w, since)
}

// A turn or a person's prompt in the delay before this runs wins. promptedFor is
// cleared, so the next turn end asks again.
const runCheckpoint = async ($: $, since: number) => {
  if (mem.isBusy || mem.personPromptAt >= since) {
    mem.promptedFor = undefined
    return
  }
  const names = (await $.command.list()).map(c => c.name)
  const name = names.find(n => n === 'checkpoint') ?? names.find(n => n.endsWith(':checkpoint'))
  if (name === undefined) {
    await fail($, 'the /checkpoint command is not listed, so no checkpoint was asked for')
    return
  }
  try {
    await $.command.run({ command: name })
  } catch (err) {
    await fail($, `/${name} was refused: ${String(err)}`)
  }
}

const tick = async ($: $) => {
  const endedAt = await $.clock.now()
  const config = await readConfig($)
  if (config === undefined) return
  const w = await where($)
  const limit = config.checkpointPercent ?? DEFAULT_PERCENT
  const percent = await percentOf($)
  const { shown, save } = await shownOf($, limit)
  statusLine($, w, shown, save)
  if ((await $.session.usage()).context.window < MIN_WINDOW) return

  if (percent < limit) {
    if ((await readCrossed($, w)) !== undefined) await $.fs.write(crossedFile(w), '')
    mem.promptedFor = undefined
    mem.toastedFor = undefined
    return
  }

  let crossed = await readCrossed($, w)
  if (crossed === undefined) {
    crossed = Math.floor((await $.clock.now()) / 1000)
    await $.fs.write(crossedFile(w), `${crossed}\n`)
  }

  if (await isFresh($, w.state, crossed)) {
    if (mem.isCompacting) return
    mem.isCompacting = true
    $.clock.after(RETRY_MS, () => void tryCompact($, w, endedAt, 0))
    return
  }

  if (mem.promptedFor !== crossed) {
    if (await hasDraft($)) return
    mem.promptedFor = crossed
    $.clock.after(RETRY_MS, () => void runCheckpoint($, endedAt))
    return
  }

  if (mem.toastedFor !== crossed) {
    mem.toastedFor = crossed
    await fail($, `context ${shown}% (save point ${save}%) and no fresh checkpoint at ${w.state}, so the backstop compacts later`)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const config = await readConfig($)
    if (config === undefined) return started
    const { shown, save } = await shownOf($, config.checkpointPercent ?? DEFAULT_PERCENT)
    statusLine($, await where($), shown, save)
    return started
  })

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) mem.isBusy = true
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind !== 'plugin') mem.personPromptAt = await $.clock.now()
    return next(e)
  }).catch(async ($, e, next) => {
    await log($, `prompt.submit hook failed: ${next.error.message ?? next.error.kind}`)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined) return done
    mem.isBusy = false
    if (e.isAborted) return done
    await tick($)
    return done
  })

  on('session.compact', async ($, e, next) => {
    if (e.agentId !== undefined || (await readConfig($)) === undefined) return next(e)
    const steer = instructions(await where($))
    const merged = e.instructions ? `${e.instructions}\n\n${steer}` : steer
    return next({ ...e, instructions: merged })
  }).catch(async ($, e, next) => {
    await log($, `the compaction steer failed, so this compaction has no role card: ${next.error.message ?? next.error.kind}`)
    return next(e)
  })
}
