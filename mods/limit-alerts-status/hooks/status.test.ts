import { describe, expect, mock, test } from 'claude-code/testing'
import type { CommandRunInput, On, SessionRateLimit } from 'claude-code'

import { fromCache, parseOffset, renderReport } from './format'

const T = { warn: 80, crit: 95 }
// 2026-10-10 12:00:00 UTC
const NOW = Date.UTC(2026, 9, 10, 12, 0, 0)
const NOW_S = NOW / 1000
const MSK = 180 // +0300

describe('report', () => {
  test('marks thresholds, shows reset time and countdown in local time', () => {
    const text = renderReport({
      source: 'session',
      five: { percent: 84, resetsAt: NOW_S + 58 * 60 },
      seven: { percent: 96.4, resetsAt: NOW_S + 5 * 86400 + 7 * 3600 },
    }, 'ru', T, NOW, MSK)
    expect(text).toBe([
      'Лимиты Claude Code',
      '⚠ Сессия (5ч): 84% — сброс 15:58 (через 58 мин)',
      '⛔ Неделя (все модели): 96% — сброс 15.10 22:00 (через 5 д 7 ч)',
      'Источник: последний ответ API этой сессии.',
    ].join('\n'))
  })

  test('says where the scoped limit comes from and how old it is', () => {
    const text = renderReport({
      source: 'session',
      five: { percent: 10 },
      seven: { percent: 20 },
      scoped: { model: 'Fable', percent: 4, resetsAt: NOW_S - 60 },
      cacheAgeMs: 12 * 60_000,
    }, 'en', T, NOW, 0)
    expect(text).toBe([
      'Claude Code limits',
      'Session (5h): 10%',
      'Week (all models): 20%',
      'Week (Fable): 4% — window already reset',
      "Source: this session's last API response. The model-scoped weekly limit comes from the monitor's cache (12 min ago).",
    ].join('\n'))
  })

  test('cache source, rate-limit pause, and no data at all', () => {
    const cached = renderReport({
      source: 'cache', five: { percent: 1 }, seven: { percent: 2 },
      cacheAgeMs: 3 * 3600_000, pausedUntil: NOW_S + 600,
    }, 'ru', T, NOW, MSK)
    expect(cached).toContain('Источник: кэш монитора (3 ч назад)')
    expect(cached).toContain('до 15:10 (после ответа 429)')
    expect(renderReport({ source: 'none' }, 'en', T, NOW, 0)).toContain('No usage data')
    // a pause already over is not mentioned
    expect(renderReport({ source: 'none', pausedUntil: NOW_S - 1 }, 'en', T, NOW, 0)).not.toContain('paused')
  })

  test('parses zone offsets and the cache format', () => {
    expect(parseOffset('+0300\n')).toBe(180)
    expect(parseOffset('-0430')).toBe(-270)
    expect(parseOffset('garbage')).toBe(0)
    const r = fromCache({
      five_hour: { utilization: 61.5, resets_at: '2026-10-10T13:00:00.346574+00:00' },
      seven_day: { utilization: 9 },
      limits: [{ kind: 'weekly_scoped', percent: 4, scope: { model: { display_name: 'Fable' } } }],
    })
    expect(r.five).toEqual({ percent: 61.5, resetsAt: NOW_S + 3600 })
    expect(r.scoped?.model).toBe('Fable')
  })
})

const HOME = '/Users/test'
const DIR = `${HOME}/.claude/scripts`

function world(on: On, files: Record<string, { text: string; mtimeMs: number }>, rateLimits: SessionRateLimit[]) {
  const registered: string[] = []
  const statuses: (string | undefined)[] = []
  mock.env(on, { HOME })
  mock.clock(on, { now: NOW })
  on('fs.read', (_$, e) => (files[e.path] ? { value: files[e.path]!.text } : { deny: `ENOENT: ${e.path}` }))
  on('fs.stat', (_$, e) => {
    const file = files[e.path]
    return file
      ? { value: { kind: 'file' as const, size: file.text.length, mtimeMs: file.mtimeMs, isLink: false } }
      : { deny: `ENOENT: ${e.path}` }
  })
  on('fs.list', () => ({ value: [] }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '+0300\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.usage', () => ({ value: { startedAt: 0, context: {} as never, rateLimits } }))
  on('session.start', () => ({ cwd: '/' }))
  on('command.register', (_$, e) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('command.run', () => ({ text: 'engine' }))
  on('ui.status', (_$, e) => {
    statuses.push(e.text)
    return { value: undefined }
  })
  return { registered, statuses }
}

const START = { cwd: '/', surface: 'terminal' as const, isInteractive: true }
const RUN = { command: 'limits', args: '' } as unknown as CommandRunInput

describe('mod', () => {
  test('registers /limits and answers it without the model', async ($, on) => {
    const cache = JSON.stringify({
      five_hour: { utilization: 61 }, seven_day: { utilization: 9 },
      limits: [{ kind: 'weekly_scoped', percent: 4, scope: { model: { display_name: 'Fable' } } }],
    })
    const files = {
      [`${DIR}/usage-monitor-cache.json`]: { text: cache, mtimeMs: NOW - 5 * 60_000 },
      [`${DIR}/usage-monitor-backoff.json`]: { text: JSON.stringify({ until: NOW_S + 900 }), mtimeMs: NOW },
    }
    const { registered, statuses } = world(on, files, [
      { kind: 'five_hour', percentUsed: 16, resetsAt: new Date(NOW + 3600_000).toISOString() },
      { kind: 'seven_day', percentUsed: 53 },
    ])
    await $.session.start(START)
    expect(registered).toEqual(['limits'])
    // a row pinned by an older version is cleared, and nothing new is pinned
    expect(statuses).toEqual([undefined])

    const { text } = await $.command.run(RUN)
    expect(text).toBe([
      'Лимиты Claude Code',
      'Сессия (5ч): 16% — сброс 16:00 (через 1 ч)',
      'Неделя (все модели): 53%',
      'Неделя (Fable): 4%',
      'Источник: последний ответ API этой сессии. Недельный лимит по модели — из кэша монитора (5 мин назад).',
      '⏸ Монитор приостановил запросы к endpoint лимитов до 15:15 (после ответа 429).',
    ].join('\n'))
  })

  test('falls back to the cache before the session has talked to the API', async ($, on) => {
    const cache = JSON.stringify({ five_hour: { utilization: 61 }, seven_day: { utilization: 9 } })
    world(on, { [`${DIR}/usage-monitor-cache.json`]: { text: cache, mtimeMs: NOW - 2 * 60_000 } }, [])
    await $.session.start(START)
    const { text } = await $.command.run(RUN)
    expect(text).toContain('Сессия (5ч): 61%')
    expect(text).toContain('Источник: кэш монитора (2 мин назад)')
  })
})
