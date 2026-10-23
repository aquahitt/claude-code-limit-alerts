import { describe, expect, mock, test } from 'claude-code/testing'
import type { CommandRunInput, On, SessionRateLimit } from 'claude-code'

import { formatMoney, freshest, fromCache, paceExpected, paceProjected, parseOffset, renderReport } from './format'

const T = { warn: 80, crit: 95 }
// 2026-10-10 12:00:00 UTC
const NOW = Date.UTC(2026, 9, 10, 12, 0, 0)
const NOW_S = NOW / 1000
const MSK = 180 // +0300

describe('report', () => {
  test('marks thresholds, shows reset time and countdown in local time', () => {
    const text = renderReport({
      five: { percent: 84, resetsAt: NOW_S + 58 * 60, from: 'session' },
      seven: { percent: 96.4, resetsAt: NOW_S + 5 * 86400 + 7 * 3600, from: 'session' },
    }, 'ru', T, NOW, MSK)
    expect(text).toBe([
      'Лимиты Claude Code',
      '⚠ Сессия (5ч): 84% — сброс 15:58 (через 58 мин)',
      '⛔ Неделя (все модели): 96% — сброс 15.10 22:00 (через 5 д 7 ч) · по графику 24%',
      'Источник: последний ответ API этой сессии.',
    ].join('\n'))
  })

  test('says where the scoped limit comes from and how old it is', () => {
    const text = renderReport({
      five: { percent: 10, from: 'session' },
      seven: { percent: 20, from: 'session' },
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
      five: { percent: 1, from: 'cache' }, seven: { percent: 2, from: 'cache' },
      cacheAgeMs: 3 * 3600_000, pausedUntil: NOW_S + 600,
    }, 'ru', T, NOW, MSK)
    expect(cached).toContain('Источник: кэш монитора (3 ч назад) — данные всего аккаунта')
    expect(cached).toContain('до 15:10 (после ответа 429)')
    expect(renderReport({}, 'en', T, NOW, 0)).toContain('No usage data')
    // a pause already over is not mentioned
    expect(renderReport({ pausedUntil: NOW_S - 1 }, 'en', T, NOW, 0)).not.toContain('paused')
  })

  test('names the source of each window when they differ', () => {
    const text = renderReport({
      five: { percent: 60, from: 'cache' }, seven: { percent: 48, from: 'session' }, cacheAgeMs: 60_000,
    }, 'ru', T, NOW, MSK)
    expect(text).toContain('Источник: Сессия (5ч) — кэш монитора (1 мин назад), Неделя (все модели) — ответ API этой сессии.')
  })

  test('weekly pace, the split by product and paid credits', () => {
    const text = renderReport({
      seven: { percent: 46, resetsAt: NOW_S + 5 * 86400, from: 'cache' },
      breakdown: [{ key: 'claude_code', name: 'Claude Code', percent: 88 }, { key: 'chat', name: 'Chats', percent: 12 }],
      spend: { amountMinor: 420, exponent: 2, currency: 'USD', percent: 42 },
      cacheAgeMs: 60_000,
    }, 'ru', T, NOW, MSK)
    expect(text).toContain('Неделя (все модели): 46% — сброс 15.10 15:00 (через 5 д) · по графику 28%')
    expect(text).toContain('Расход недели по продуктам: Claude Code 88%, чаты 12%')
    expect(text).toContain('💳 Платные usage credits: $4.20 (42% лимита расходов)')
    const en = renderReport({ breakdown: [{ key: 'chat', name: 'Chats', percent: 12 }] }, 'en', T, NOW, 0)
    expect(en).toContain('Weekly usage by product: Chats 12%')
  })

  test('pace needs half a day of the window; money keeps its currency', () => {
    expect(paceExpected(NOW_S + 7 * 86400 - 3600, NOW_S)).toBeUndefined()
    expect(paceExpected(NOW_S + 86400, NOW_S)).toBe(85)
    expect(paceExpected(undefined, NOW_S)).toBeUndefined()
    expect(formatMoney({ amountMinor: 1999, exponent: 2, currency: 'EUR', percent: 0 })).toBe('€19.99')
    expect(formatMoney({ amountMinor: 500, exponent: 0, currency: 'JPY', percent: 0 })).toBe('500 JPY')
  })

  test('a week behind pace says how much resets unused', () => {
    // 4 of 7 days gone: on pace is 57%, 20% now projects to 35% at the reset
    expect(paceProjected(20, NOW_S + 3 * 86400, NOW_S)).toBe(35)
    const behind = renderReport({ seven: { percent: 20, resetsAt: NOW_S + 3 * 86400, from: 'cache' } }, 'ru', T, NOW, MSK)
    expect(behind).toContain('Неделя (все модели): 20% — сброс 13.10 15:00 (через 3 д) · по графику 57% · к сбросу ~35% (останется 65%)')
    const en = renderReport({ seven: { percent: 20, resetsAt: NOW_S + 3 * 86400, from: 'cache' } }, 'en', T, NOW, 0)
    expect(en).toContain('· on pace: 57% · ~35% by reset (65% left unused)')
    // within 5 points of the pace: no projection
    const near = renderReport({ seven: { percent: 54, resetsAt: NOW_S + 3 * 86400, from: 'cache' } }, 'ru', T, NOW, MSK)
    expect(near).not.toContain('к сбросу')
  })

  test('picks the fresher reading of a window', () => {
    const r = NOW_S + 3600
    // same window: usage only grows, so the higher percent is the later one
    expect(freshest({ percent: 32, resetsAt: r }, { percent: 60, resetsAt: r + 2 }, NOW_S)?.percent).toBe(60)
    // a later window wins even at a lower percent
    expect(freshest({ percent: 90, resetsAt: r }, { percent: 5, resetsAt: r + 5 * 3600 }, NOW_S)?.percent).toBe(5)
    // a window whose reset passed is dropped
    expect(freshest({ percent: 95, resetsAt: NOW_S - 1 }, { percent: 7, resetsAt: r }, NOW_S)?.percent).toBe(7)
    expect(freshest(undefined, { percent: 7, resetsAt: r }, NOW_S)?.percent).toBe(7)
    expect(freshest(undefined, undefined, NOW_S)).toBeUndefined()
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
    expect(r.breakdown).toBeUndefined()
    expect(r.spend).toBeUndefined()
    const extra = fromCache({
      spend: { percent: 0, used: { amount_minor: 0, currency: 'USD', exponent: 2 } },
      seven_day_breakdown: { rows: [{ key: 'claude_code', display_name: 'Claude Code', percent: 100 },
        { key: 'chat', display_name: 'Chats', percent: 0 }] },
    })
    // nothing spent is not a credits line; one product (others at 0%) is no split
    expect(extra.spend).toBeUndefined()
    expect(extra.breakdown).toBeUndefined()
    const two = fromCache({ seven_day_breakdown: { rows: [
      { key: 'claude_code', display_name: 'Claude Code', percent: 90 },
      { key: 'chat', display_name: 'Chats', percent: 10 },
      { key: 'cowork', display_name: 'Cowork', percent: 0 }] } })
    expect(two.breakdown?.map(s => s.key)).toEqual(['claude_code', 'chat'])
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

  test('an idle session shows the account-wide cache when it is fresher', async ($, on) => {
    const reset = new Date(NOW + 3600_000).toISOString()
    const cache = JSON.stringify({
      five_hour: { utilization: 60, resets_at: reset }, seven_day: { utilization: 40 },
    })
    world(on, { [`${DIR}/usage-monitor-cache.json`]: { text: cache, mtimeMs: NOW - 60_000 } }, [
      { kind: 'five_hour', percentUsed: 32, resetsAt: reset },
      { kind: 'seven_day', percentUsed: 48 },
    ])
    await $.session.start(START)
    const { text } = await $.command.run(RUN)
    expect(text).toContain('Сессия (5ч): 60%')
    expect(text).toContain('Неделя (все модели): 48%')
    expect(text).toContain('Источник: Сессия (5ч) — кэш монитора (1 мин назад), Неделя (все модели) — ответ API этой сессии.')
  })

  test("ignores another account's cache after switching accounts", async ($, on) => {
    const cache = JSON.stringify({
      _account: 'other-account:other-org', five_hour: { utilization: 61 }, seven_day: { utilization: 9 },
    })
    world(on, {
      [`${DIR}/usage-monitor-cache.json`]: { text: cache, mtimeMs: NOW - 60_000 },
      [`${HOME}/.claude.json`]: {
        text: JSON.stringify({ oauthAccount: { accountUuid: 'me', organizationUuid: 'my-org' } }), mtimeMs: NOW,
      },
    }, [])
    await $.session.start(START)
    const { text } = await $.command.run(RUN)
    expect(text).not.toContain('61%')
    expect(text).toContain('Нет данных о лимитах')
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
