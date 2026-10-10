// Pure rendering of the /limits report. Everything that depends on the host
// (the clock, the time zone, the files) is passed in, so the tests can pin it.

import type { SessionRateLimit } from 'claude-code'

export type Lang = 'ru' | 'en'

export type Thresholds = { warn: number; crit: number }

// resetsAt is epoch seconds, as the statusline's stdin carries it.
export type Window = { percent: number; resetsAt?: number }

export type Reading = {
  five?: Window
  seven?: Window
  // The weekly model-scoped limit; only usage-monitor-cache.json has it.
  scoped?: Window & { model: string }
}

export type Report = {
  five?: Window
  seven?: Window
  scoped?: Window & { model: string }
  // Where five/seven came from: this session's last API response, or the cache.
  source: 'session' | 'cache' | 'none'
  cacheAgeMs?: number
  // usage-monitor.sh's pause after an HTTP 429, epoch seconds.
  pausedUntil?: number
}

type CacheWindow = { utilization?: number | null; resets_at?: string | null }
type CacheLimit = {
  kind?: string
  percent?: number | null
  resets_at?: string | null
  scope?: { model?: { display_name?: string } } | null
}

export type Cache = {
  five_hour?: CacheWindow | null
  seven_day?: CacheWindow | null
  limits?: CacheLimit[] | null
}

function epoch(iso: string | null | undefined): number | undefined {
  if (!iso) {
    return undefined
  }
  const ms = Date.parse(iso)
  return Number.isNaN(ms) ? undefined : Math.floor(ms / 1000)
}

function cacheWindow(w: CacheWindow | null | undefined): Window | undefined {
  return typeof w?.utilization === 'number' ? { percent: w.utilization, resetsAt: epoch(w.resets_at) } : undefined
}

export function fromCache(cache: Cache): Reading {
  const reading: Reading = { five: cacheWindow(cache.five_hour), seven: cacheWindow(cache.seven_day) }
  const scoped = (cache.limits ?? []).find(x => x.kind === 'weekly_scoped')
  const model = scoped?.scope?.model?.display_name
  if (typeof scoped?.percent === 'number' && model) {
    reading.scoped = { model, percent: scoped.percent, resetsAt: epoch(scoped.resets_at) }
  }
  return reading
}

// The engine's own reading, from the last API response's headers: current
// while the session talks to the API, but without the scoped limit.
export function fromRateLimits(limits: readonly SessionRateLimit[]): Reading {
  const pick = (kind: string): Window | undefined => {
    const limit = limits.find(x => x.kind === kind)
    return limit ? { percent: limit.percentUsed, resetsAt: epoch(limit.resetsAt) } : undefined
  }
  return { five: pick('five_hour'), seven: pick('seven_day') }
}

// "+0300" / "-0430" -> minutes east of UTC; anything else -> 0.
export function parseOffset(text: string): number {
  const m = /^([+-])(\d{2})(\d{2})/.exec(text.trim())
  if (!m) {
    return 0
  }
  const minutes = Number(m[2]) * 60 + Number(m[3])
  return m[1] === '-' ? -minutes : minutes
}

const T = {
  ru: {
    title: 'Лимиты Claude Code',
    five: 'Сессия (5ч)',
    seven: 'Неделя (все модели)',
    scoped: (m: string) => `Неделя (${m})`,
    resetAt: 'сброс',
    passed: 'окно уже сброшено',
    inPrefix: 'через',
    min: 'мин',
    hour: 'ч',
    day: 'д',
    ago: 'назад',
    fromSession: 'Источник: последний ответ API этой сессии.',
    scopedFromCache: (age: string) => `Недельный лимит по модели — из кэша монитора (${age}).`,
    fromCache: (age: string) => `Источник: кэш монитора (${age}) — в этой сессии ещё не было ответа API.`,
    none: 'Нет данных о лимитах: в этой сессии ещё не было ответа API, а кэша монитора нет.',
    paused: (at: string) => `⏸ Монитор приостановил запросы к endpoint лимитов до ${at} (после ответа 429).`,
  },
  en: {
    title: 'Claude Code limits',
    five: 'Session (5h)',
    seven: 'Week (all models)',
    scoped: (m: string) => `Week (${m})`,
    resetAt: 'resets',
    passed: 'window already reset',
    inPrefix: 'in',
    min: 'min',
    hour: 'h',
    day: 'd',
    ago: 'ago',
    fromSession: "Source: this session's last API response.",
    scopedFromCache: (age: string) => `The model-scoped weekly limit comes from the monitor's cache (${age}).`,
    fromCache: (age: string) => `Source: the monitor's cache (${age}) — no API response in this session yet.`,
    none: "No usage data: no API response in this session yet, and no monitor cache.",
    paused: (at: string) => `⏸ The monitor paused requests to the usage endpoint until ${at} (after an HTTP 429).`,
  },
} as const

function two(n: number): string {
  return String(n).padStart(2, '0')
}

// Local wall-clock parts of an epoch, given the zone offset in minutes.
function local(epochSec: number, offsetMin: number): Date {
  return new Date(epochSec * 1000 + offsetMin * 60_000)
}

function clock(epochSec: number, nowSec: number, offsetMin: number): string {
  const at = local(epochSec, offsetMin)
  const now = local(nowSec, offsetMin)
  const hm = `${two(at.getUTCHours())}:${two(at.getUTCMinutes())}`
  const sameDay = at.getUTCFullYear() === now.getUTCFullYear()
    && at.getUTCMonth() === now.getUTCMonth()
    && at.getUTCDate() === now.getUTCDate()
  return sameDay ? hm : `${two(at.getUTCDate())}.${two(at.getUTCMonth() + 1)} ${hm}`
}

function duration(seconds: number, lang: Lang): string {
  const l = T[lang]
  const minutes = Math.max(1, Math.round(seconds / 60))
  if (minutes < 60) {
    return `${minutes} ${l.min}`
  }
  const hours = Math.floor(minutes / 60)
  if (hours < 24) {
    const rest = minutes % 60
    return rest ? `${hours} ${l.hour} ${rest} ${l.min}` : `${hours} ${l.hour}`
  }
  const days = Math.floor(hours / 24)
  const rest = hours % 24
  return rest ? `${days} ${l.day} ${rest} ${l.hour}` : `${days} ${l.day}`
}

function line(label: string, w: Window, lang: Lang, t: Thresholds, nowSec: number, offsetMin: number): string {
  const l = T[lang]
  const mark = w.percent >= t.crit ? '⛔ ' : w.percent >= t.warn ? '⚠ ' : ''
  let reset = ''
  if (w.resetsAt !== undefined) {
    reset = w.resetsAt <= nowSec
      ? ` — ${l.passed}`
      : ` — ${l.resetAt} ${clock(w.resetsAt, nowSec, offsetMin)} (${l.inPrefix} ${duration(w.resetsAt - nowSec, lang)})`
  }
  return `${mark}${label}: ${Math.floor(w.percent)}%${reset}`
}

export function renderReport(r: Report, lang: Lang, t: Thresholds, nowMs: number, offsetMin: number): string {
  const l = T[lang]
  const nowSec = Math.floor(nowMs / 1000)
  const age = r.cacheAgeMs === undefined ? '' : `${duration(r.cacheAgeMs / 1000, lang)} ${l.ago}`

  const lines: string[] = [l.title]
  if (r.five) lines.push(line(l.five, r.five, lang, t, nowSec, offsetMin))
  if (r.seven) lines.push(line(l.seven, r.seven, lang, t, nowSec, offsetMin))
  if (r.scoped) lines.push(line(l.scoped(r.scoped.model), r.scoped, lang, t, nowSec, offsetMin))

  if (r.source === 'none' && !r.scoped) {
    lines.push(l.none)
  } else if (r.source === 'session') {
    lines.push(r.scoped ? `${l.fromSession} ${l.scopedFromCache(age)}` : l.fromSession)
  } else if (r.source === 'cache') {
    lines.push(l.fromCache(age))
  }

  if (r.pausedUntil !== undefined && r.pausedUntil > nowSec) {
    lines.push(l.paused(clock(r.pausedUntil, nowSec, offsetMin)))
  }
  return lines.join('\n')
}
