import type { EngineInterface, PluginOptions, Register } from 'claude-code'

import { fromCache, fromRateLimits, render, STALE_MS, type Cache, type Lang, type Reading } from './format'

const CACHE_FILE = 'usage-monitor-cache.json'
// The cache file is tiny and local; re-reading it this often costs nothing
// and keeps the line within one launchd period of the truth.
const REFRESH_MS = 30 * 1000

// mtime of a file, or undefined when it is not there (fs.stat rejects).
async function mtime($: EngineInterface, path: string): Promise<number | undefined> {
  try {
    const stat = await $.fs.stat(path)
    return stat.kind === 'file' ? stat.mtimeMs : undefined
  } catch {
    return undefined
  }
}

// Same chain as the bash scripts: explicit option, UM_STATE_DIR, the classic
// install's ~/.claude/scripts. CLAUDE_PLUGIN_DATA is deliberately absent (see
// CLAUDE.md); the plugin install's data directory is found by name instead.
async function locate($: EngineInterface, options: PluginOptions): Promise<string | undefined> {
  const explicit = typeof options.state_dir === 'string' ? options.state_dir.trim() : ''
  if (explicit) {
    return `${explicit}/${CACHE_FILE}`
  }

  const fromEnv = await $.env.get('UM_STATE_DIR')
  if (fromEnv) {
    return `${fromEnv}/${CACHE_FILE}`
  }

  const home = await $.env.get('HOME')
  if (!home) {
    return undefined
  }

  const classic = `${home}/.claude/scripts/${CACHE_FILE}`
  if ((await mtime($, classic)) !== undefined) {
    return classic
  }

  const dataRoot = `${home}/.claude/plugins/data`
  let entries
  try {
    entries = await $.fs.list(dataRoot)
  } catch {
    return undefined
  }
  for (const entry of entries) {
    if (!entry.name.startsWith('limit-alerts-')) {
      continue
    }
    const candidate = `${dataRoot}/${entry.name}/${CACHE_FILE}`
    if ((await mtime($, candidate)) !== undefined) {
      return candidate
    }
  }

  return undefined
}

async function readCache($: EngineInterface, options: PluginOptions): Promise<{ reading: Reading; ageMs: number } | undefined> {
  const path = await locate($, options)
  const mtimeMs = path === undefined ? undefined : await mtime($, path)
  if (path === undefined || mtimeMs === undefined) {
    return undefined
  }

  try {
    const reading = fromCache(JSON.parse(await $.fs.read(path)) as Cache)
    return reading && { reading, ageMs: (await $.clock.now()) - mtimeMs }
  } catch {
    // Mid-write or malformed: treat as absent this tick.
    return undefined
  }
}

// A fresh cache wins (it alone has the scoped weekly limit); otherwise the
// engine's own reading; otherwise a stale cache, marked with its age.
async function refresh($: EngineInterface, options: PluginOptions): Promise<void> {
  const lang: Lang = options.lang === 'en' ? 'en' : 'ru'
  const thresholds = {
    warn: typeof options.warn === 'number' ? options.warn : 80,
    crit: typeof options.crit === 'number' ? options.crit : 95,
  }

  const cached = await readCache($, options)
  if (cached && cached.ageMs < STALE_MS) {
    $.ui.status(render(cached.reading, lang, thresholds))
    return
  }

  const live = fromRateLimits((await $.session.usage()).rateLimits)
  if (live) {
    $.ui.status(render(live, lang, thresholds))
    return
  }

  $.ui.status(cached ? render(cached.reading, lang, thresholds, cached.ageMs) : undefined)
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)

    await refresh($, options)
    $.clock.every(REFRESH_MS, () => void refresh($, options))

    return result
  })

  // The Stop hook rewrites the cache right after a turn; pick it up without
  // waiting for the next tick.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    $.clock.after(2000, () => void refresh($, options))

    return result
  })
}
