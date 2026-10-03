import { describe, expect, mock, test } from 'claude-code/testing'
import type { On, SessionRateLimit } from 'claude-code'

import { fromCache, render, STALE_MS } from './format'

const HOME = '/Users/test'
const CACHE = `${HOME}/.claude/scripts/usage-monitor-cache.json`
const NOW = 1_000_000_000_000

const CACHE_JSON = JSON.stringify({
  five_hour: { utilization: 62.4 },
  seven_day: { utilization: 9 },
  limits: [
    { kind: 'session', percent: 62 },
    { kind: 'weekly_scoped', percent: 4, scope: { model: { display_name: 'Fable' } } },
  ],
})

// Answers everything the mod asks of the engine beneath it: env, clock, the
// file system (the `files` map), session.usage, and records the status line.
function world(on: On, files: Record<string, { text: string; mtimeMs: number }>, rateLimits: SessionRateLimit[] = []) {
  const shown: (string | undefined)[] = []
  mock.env(on, { HOME })
  const clock = mock.clock(on, { now: NOW })
  on('fs.read', (_$, e) => ({ value: files[e.path]!.text }))
  on('fs.stat', (_$, e) => {
    const file = files[e.path]
    return file
      ? { value: { kind: 'file' as const, size: file.text.length, mtimeMs: file.mtimeMs, isLink: false } }
      : { deny: `ENOENT: ${e.path}` }
  })
  on('fs.list', () => ({ value: [] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: {} as never, rateLimits } }))
  on('session.start', () => ({ cwd: '/' }))
  on('ui.status', (_$, e) => {
    shown.push(e.text)
    return { value: undefined }
  })
  return { shown, clock }
}

const START = { cwd: '/', surface: 'terminal' as const, isInteractive: true }

describe('format', () => {
  test('marks the worst limit', () => {
    const reading = fromCache(JSON.parse(CACHE_JSON))!
    expect(render(reading, 'ru', { warn: 80, crit: 95 })).toBe('5ч 62% · 7д 9% · нед. Fable 4%')
    expect(render({ five: 81, seven: 9 }, 'en', { warn: 80, crit: 95 })).toBe('⚠ 5h 81% · 7d 9%')
    expect(render({ five: 10, seven: 96 }, 'en', { warn: 80, crit: 95 })).toBe('⛔ 5h 10% · 7d 96%')
  })

  test('says how old a stale reading is', () => {
    expect(render({ five: 1, seven: 2 }, 'en', { warn: 80, crit: 95 }, STALE_MS + 60_000)).toBe('5h 1% · 7d 2% (16m ago)')
  })
})

describe('mod', () => {
  test('shows the fresh cache on session start', async ($, on) => {
    const { shown } = world(on, { [CACHE]: { text: CACHE_JSON, mtimeMs: NOW - 60_000 } })
    await $.session.start(START)
    expect(shown.at(-1)).toBe('5ч 62% · 7д 9% · нед. Fable 4%')
  })

  test('falls back to the engine reading without a cache', async ($, on) => {
    const { shown } = world(on, {}, [
      { kind: 'five_hour', percentUsed: 85 },
      { kind: 'seven_day', percentUsed: 20 },
    ])
    await $.session.start(START)
    expect(shown.at(-1)).toBe('⚠ 5ч 85% · 7д 20%')
  })

  test('keeps a stale cache, with its age, when the engine has nothing', async ($, on) => {
    const { shown } = world(on, { [CACHE]: { text: CACHE_JSON, mtimeMs: NOW - 2 * 3600_000 } })
    await $.session.start(START)
    expect(shown.at(-1)).toBe('5ч 62% · 7д 9% · нед. Fable 4% (2ч назад)')
  })

  test('english option and periodic refresh', { options: { lang: 'en' } }, async ($, on) => {
    const files = { [CACHE]: { text: CACHE_JSON, mtimeMs: NOW } }
    const { shown, clock } = world(on, files)
    await $.session.start(START)
    files[CACHE] = { text: JSON.stringify({ five_hour: { utilization: 97 }, seven_day: { utilization: 9 } }), mtimeMs: NOW + 20_000 }
    await clock.advance(30_000)
    expect(shown.at(-1)).toBe('⛔ 5h 97% · 7d 9%')
  })
})
