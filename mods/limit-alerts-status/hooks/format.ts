// Pure rendering of a usage reading into one status line. Mirrors the LIMITS
// segment of scripts/statusline-with-limits.sh, minus ANSI colors: a plugin
// status line is plain text, so severity is a leading mark instead.

import type { SessionRateLimit } from 'claude-code'

export type Lang = 'ru' | 'en'

export type Thresholds = { warn: number; crit: number }

export type Reading = {
  five: number
  seven: number
  // The weekly model-scoped limit; only usage-monitor-cache.json has it.
  scoped?: { model: string; percent: number }
}

type Window = { utilization?: number | null }
type Limit = {
  kind?: string
  percent?: number | null
  scope?: { model?: { display_name?: string } } | null
}

export type Cache = {
  five_hour?: Window | null
  seven_day?: Window | null
  limits?: Limit[] | null
}

const LABELS: Record<Lang, { l5: string; l7: string; wk: string; min: string; hour: string; ago: string }> = {
  ru: { l5: '5ч', l7: '7д', wk: 'нед.', min: 'м', hour: 'ч', ago: 'назад' },
  en: { l5: '5h', l7: '7d', wk: 'wk', min: 'm', hour: 'h', ago: 'ago' },
}

// Older than this, the cache counts as stale: the launchd agent refreshes it
// every 5 min and the Stop hook after each turn, so 15 min of silence means
// neither is running.
export const STALE_MS = 15 * 60 * 1000

export function fromCache(cache: Cache): Reading | undefined {
  const five = cache.five_hour?.utilization
  const seven = cache.seven_day?.utilization
  if (typeof five !== 'number' || typeof seven !== 'number') {
    return undefined
  }

  const reading: Reading = { five, seven }
  const scoped = (cache.limits ?? []).find(x => x.kind === 'weekly_scoped')
  const model = scoped?.scope?.model?.display_name
  if (typeof scoped?.percent === 'number' && model) {
    reading.scoped = { model, percent: scoped.percent }
  }

  return reading
}

// The engine's own reading, from the last API response's headers: always
// current while the session talks to the API, but without the scoped limit.
export function fromRateLimits(limits: readonly SessionRateLimit[]): Reading | undefined {
  const five = limits.find(x => x.kind === 'five_hour')?.percentUsed
  const seven = limits.find(x => x.kind === 'seven_day')?.percentUsed
  if (typeof five !== 'number' || typeof seven !== 'number') {
    return undefined
  }

  return { five, seven }
}

function age(ms: number, lang: Lang): string {
  const l = LABELS[lang]
  const minutes = Math.floor(ms / 60000)
  const text = minutes < 60 ? `${minutes}${l.min}` : `${Math.floor(minutes / 60)}${l.hour}`
  return `${text} ${l.ago}`
}

export function render(reading: Reading, lang: Lang, t: Thresholds, ageMs = 0): string {
  const l = LABELS[lang]
  const parts = [`${l.l5} ${Math.floor(reading.five)}%`, `${l.l7} ${Math.floor(reading.seven)}%`]
  const percents = [reading.five, reading.seven]

  if (reading.scoped) {
    parts.push(`${l.wk} ${reading.scoped.model} ${Math.floor(reading.scoped.percent)}%`)
    percents.push(reading.scoped.percent)
  }

  const top = Math.max(...percents)
  const mark = top >= t.crit ? '⛔ ' : top >= t.warn ? '⚠ ' : ''
  const stale = ageMs >= STALE_MS ? ` (${age(ageMs, lang)})` : ''

  return `${mark}${parts.join(' · ')}${stale}`
}
