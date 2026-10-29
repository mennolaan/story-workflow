import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// Every path holds spaces, as a repo path can.
const ROOT = '/Users/dev/Repo/My Repo - A'
const CONFIG = `${ROOT}/.claude/story.json`
const CWD = `${ROOT}/.claude/worktrees/wt 1`
const PLANS = `${ROOT}/.plans`
const STATE = `${PLANS}/story-x.d/implement.md`
const CROSSED = `${PLANS}/.sessions/local_h1.crossed`
const T0 = 1_800_000_000_000

type File = { text: string; mtimeMs: number }

const checkpoint = (mode: 'continue' | 'wait') =>
  [
    '# Checkpoint implement story-x',
    ...Array.from({ length: 10 }, () => 'Done and verified: a step with its evidence, filler text.'),
    '## Next action',
    'run the matrix again',
    `CHECKPOINT-READY: ${STATE} | ${mode}`,
  ].join('\n')

type World = {
  files: Map<string, File>
  compacts: string[]
  commands: string[]
  prompts: string[]
  toasts: string[]
  statuses: (string | undefined)[]
  writes: string[]
}

const world = (
  on: On,
  options: { percent?: number; tokens?: number; rawMax?: number; window?: number; draft?: string; state?: File; crossed?: number; worktreePercent?: number; headless?: boolean; compactError?: string; noConfig?: boolean },
): World => {
  const w: World = { files: new Map(), compacts: [], commands: [], prompts: [], toasts: [], statuses: [], writes: [] }
  w.files.set(`${CWD}/.git`, { text: `gitdir: ${ROOT}/.git/worktrees/wt 1\n`, mtimeMs: T0 })
  if (!options.noConfig) w.files.set(CONFIG, { text: '{"checkpointPercent": 35}', mtimeMs: T0 })
  if (options.worktreePercent !== undefined) {
    w.files.set(`${CWD}/.claude/story.json`, { text: `{"checkpointPercent": ${options.worktreePercent}}`, mtimeMs: T0 })
  }
  w.files.set(`${PLANS}/.sessions/local_h1.json`, {
    text: JSON.stringify({ role: 'implement', slug: 'story-x', parent: 'local_orch' }),
    mtimeMs: T0,
  })
  if (options.state) w.files.set(STATE, options.state)
  if (options.crossed !== undefined) w.files.set(CROSSED, { text: `${options.crossed}\n`, mtimeMs: T0 })

  mock.env(on, { CLAUDE_CODE_HOST_SESSION_ID: 'local_h1' })
  on('session.cwd', () => ({ value: CWD }))
  on('session.id', () => ({ value: 'sid-1' }))
  on('session.surfaces', () => ({ value: options.headless ? [] : ['terminal' as const] }))
  on('session.usage', (_, e) => {
    const window = options.window ?? 1_000_000
    const tokens = options.tokens ?? ((options.percent ?? 0) * window) / 100
    // Like the engine: the breakdown is absent unless the call asks for it.
    const asked = (e as { breakdown?: string } | undefined)?.breakdown !== undefined
    const breakdown = options.rawMax === undefined || !asked ? {} : { breakdown: { rawMaxTokens: options.rawMax } }
    return { value: { startedAt: 0, context: { tokens, window, percent: Math.floor((tokens * 100) / window), ...breakdown }, rateLimits: [] } } as never
  })
  on('prompt.read', () => ({ value: { text: options.draft ?? '', cursor: 0 } }))
  on('fs.exists', (_, e) => ({ value: w.files.has(e.path) }))
  on('fs.read', (_, e) => {
    const f = w.files.get(e.path)
    if (!f) throw new Error(`no file ${e.path}`)
    return { value: f.text }
  })
  on('fs.stat', (_, e) => {
    const f = w.files.get(e.path)
    if (!f) throw new Error(`no file ${e.path}`)
    return { value: { kind: 'file', size: f.text.length, mtimeMs: f.mtimeMs, isLink: false } }
  })
  on('fs.write', (_, e) => {
    w.writes.push(e.path)
    w.files.set(e.path, { text: e.text, mtimeMs: T0 })
    return { value: undefined }
  })
  on('command.list', () => ({ value: [{ name: 'checkpoint', description: 'Save the session state.', source: 'plugin' as const }] }))
  on('command.run', (_, e) => {
    w.commands.push(e.command)
    return { text: '' }
  })
  on('prompt.submit', (_, e) => {
    w.prompts.push(e.text)
    return { text: e.text }
  })
  on('session.compact', (_, e) => {
    if (options.compactError !== undefined) throw new Error(options.compactError)
    w.compacts.push(e.instructions ?? '')
    return { messages: [{ role: 'user', text: 'summary', toolUses: [] }] }
  })
  on('ui.toast', (_, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.status', (_, e) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('session.start', (_, e) => e)
  return w
}

const turnEnd = (extra: { isAborted?: boolean; agentId?: string } = {}) => ({
  answer: 'done',
  durationMs: 1,
  isAborted: extra.isAborted ?? false,
  reason: extra.isAborted ? ('aborted' as const) : ('answer' as const),
  turnId: 't1',
  ...(extra.agentId ? { agentId: extra.agentId } : {}),
})

const fresh = (mode: 'continue' | 'wait') => ({ text: checkpoint(mode), mtimeMs: T0 })
const crossedAt = Math.floor(T0 / 1000) - 60

const settle = async (clock: { advance: (ms: number) => Promise<void> }) => {
  for (let i = 0; i < 10; i++) await clock.advance(500)
}

test('below the save point: no compaction, no checkpoint, a status line', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 20 })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(0)
  expect(w.commands.length).toBe(0)
  expect(w.statuses).toContain('ctx 20% · save 35% · implement')
})

test('at the save point with a fresh checkpoint: compacts once, steered to the state file', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('wait'), crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(1)
  expect(w.compacts[0]).toContain(STATE)
  expect(w.compacts[0]).toContain('IMPLEMENT session of story story-x')
  expect(w.commands.length).toBe(0)
  expect(w.files.get(CROSSED)?.text).toBe('')
})

test('config comes from the main checkout, not from the worktree of the .git file', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 32, state: fresh('wait'), crossed: crossedAt, worktreePercent: 90 })
  w.files.set(CONFIG, { text: '{"checkpointPercent": 30}', mtimeMs: T0 })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(1)
})

test('a wait checkpoint gets no resume prompt', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('wait'), crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(1)
  expect(w.prompts.length).toBe(0)
})

test('a continue checkpoint resumes from the next action', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('continue'), crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.prompts).toEqual([`Continue from ${STATE}: next action run the matrix again`])
})

test('a draft in the prompt box blocks the resume prompt', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('continue'), crossed: crossedAt, draft: 'my own words' })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(1)
  expect(w.prompts.length).toBe(0)
})

test('a stale checkpoint asks for /checkpoint once, then toasts and leaves the context', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 40, state: { text: 'short', mtimeMs: T0 } })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.commands).toEqual(['checkpoint'])
  expect(w.compacts.length).toBe(0)
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.commands).toEqual(['checkpoint'])
  expect(w.compacts.length).toBe(0)
  expect(w.toasts.some(t => t.includes('no fresh checkpoint'))).toBe(true)
})

test('a checkpoint older than the crossing is stale', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 40, state: { text: checkpoint('continue'), mtimeMs: T0 - 3_600_000 }, crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(0)
  expect(w.commands).toEqual(['checkpoint'])
})

test('an aborted turn: no compaction, no checkpoint prompt, no resume', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 50, state: fresh('continue'), crossed: crossedAt })
  await $.turn.complete(turnEnd({ isAborted: true }))
  await settle(clock)
  expect(w.compacts.length).toBe(0)
  expect(w.commands.length).toBe(0)
  expect(w.prompts.length).toBe(0)
})

test("a subagent's turn: no action", async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 50, state: fresh('continue'), crossed: crossedAt })
  await $.turn.complete(turnEnd({ agentId: 'a1' }))
  await settle(clock)
  expect(w.compacts.length).toBe(0)
  expect(w.commands.length).toBe(0)
  expect(w.prompts.length).toBe(0)
  expect(w.statuses.length).toBe(0)
})

test('a manual compaction is steered to the state file too', async ($, on) => {
  mock.clock(on, { now: T0 })
  const w = world(on, { percent: 10 })
  const messages = [{ role: 'user' as const, text: 'hi', toolUses: [] }]
  await $.session.compact({ trigger: 'manual', instructions: 'keep the plan', messages })
  expect(w.compacts.length).toBe(1)
  expect(w.compacts[0]).toContain('keep the plan')
  expect(w.compacts[0]).toContain(STATE)
})

test('a prompt the person sends after the turn ends blocks the resume prompt', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('continue'), crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await $.prompt.submit({ text: 'my next question', origin: { kind: 'composer' } } as Parameters<typeof $.prompt.submit>[0])
  await settle(clock)
  expect(w.compacts.length).toBe(1)
  expect(w.prompts).toEqual(['my next question'])
})

const LOG = `${PLANS}/.sessions/local_h1.log`

test('a headless host compacts with /compact, never with $.session.compact', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('continue'), crossed: crossedAt, headless: true })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.commands).toEqual(['compact'])
  expect(w.compacts.length).toBe(0)
  expect(w.files.get(CROSSED)?.text).toBe('')
  expect(w.prompts.length).toBe(1)
})

test('a refusal that repeats is logged once, with its error text, and not retried 40 times', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 36, state: fresh('wait'), crossed: crossedAt, compactError: 'refused' })
  await $.turn.complete(turnEnd())
  for (let i = 0; i < 50; i++) await clock.advance(500)
  const log = w.files.get(LOG)?.text ?? ''
  expect(log).toContain('compaction did not start after 3 tries')
  expect(log).toContain('HooksError')
  expect(log.trim().split('\n').length).toBe(1)
  expect(w.compacts.length).toBe(0)
})

test('a continue checkpoint without a valid sentinel line is logged, not resumed in silence', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const broken = { text: checkpoint('continue').replace(/\| continue$/, 'continue'), mtimeMs: T0 }
  const w = world(on, { percent: 36, state: broken, crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(1)
  expect(w.prompts.length).toBe(0)
  expect(w.files.get(LOG)?.text ?? '').toContain('not a CHECKPOINT-READY sentinel')
})

test('a 200K window: no checkpoint prompt, no compaction, no resume', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 50, window: 200_000, state: fresh('continue'), crossed: crossedAt })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.compacts.length).toBe(0)
  expect(w.commands.length).toBe(0)
  expect(w.prompts.length).toBe(0)
})

test('a 200K window with a stale checkpoint: no /checkpoint, no toast', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 50, window: 200_000, state: { text: 'short', mtimeMs: T0 } })
  await $.turn.complete(turnEnd())
  await settle(clock)
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.commands.length).toBe(0)
  expect(w.toasts.length).toBe(0)
})

test('a prompt the person sends before /checkpoint runs blocks it, and the next turn end asks again', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 40, state: { text: 'short', mtimeMs: T0 } })
  await $.turn.complete(turnEnd())
  await $.prompt.submit({ text: 'my next question', origin: { kind: 'composer' } } as Parameters<typeof $.prompt.submit>[0])
  await settle(clock)
  expect(w.commands).toEqual([])
  await clock.advance(1_000)
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.commands).toEqual(['checkpoint'])
})

test('a turn that starts before /checkpoint runs blocks it', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 40, state: { text: 'short', mtimeMs: T0 } })
  await $.turn.complete(turnEnd())
  await $.turn.start({ turnId: 't2' } as Parameters<typeof $.turn.start>[0])
  await settle(clock)
  expect(w.commands).toEqual([])
})

test('no .claude/story.json: no status line, no file write, no compaction, no steer', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { percent: 50, state: fresh('continue'), crossed: crossedAt, noConfig: true })
  await $.session.start({ source: 'startup', cwd: CWD } as Parameters<typeof $.session.start>[0])
  await $.turn.complete(turnEnd())
  await settle(clock)
  const messages = [{ role: 'user' as const, text: 'hi', toolUses: [] }]
  await $.session.compact({ trigger: 'manual', instructions: 'keep the plan', messages })
  expect(w.statuses).toEqual([])
  expect(w.writes).toEqual([])
  expect(w.commands).toEqual([])
  expect(w.prompts).toEqual([])
  expect(w.toasts).toEqual([])
  expect(w.compacts).toEqual(['keep the plan'])
})

test('the status shows the percent of the composer: 252000 tokens of a 432000 backstop is 58%, save point 81%', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { tokens: 252_000, rawMax: 432_000 })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.statuses).toContain('ctx 58% · save 81% · implement')
  expect(w.commands).toEqual([])
  expect(w.compacts.length).toBe(0)
})

test('360000 tokens: the status shows 83% and the rule still runs at the save point of the model window', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, { tokens: 360_000, rawMax: 432_000, state: { text: 'short', mtimeMs: T0 } })
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.statuses).toContain('ctx 83% · save 81% · implement')
  expect(w.commands).toEqual(['checkpoint'])
  await $.turn.complete(turnEnd())
  await settle(clock)
  expect(w.toasts).toContain(`context-keeper: context 83% (save point 81%) and no fresh checkpoint at ${STATE}, so the backstop compacts later`)
})

test('without a usage breakdown the status falls back to the model window', async ($, on) => {
  mock.clock(on, { now: T0 })
  const w = world(on, { tokens: 360_000 })
  await $.session.start({ source: 'startup', cwd: CWD } as Parameters<typeof $.session.start>[0])
  expect(w.statuses).toEqual(['ctx 36% · save 35% · implement'])
})
