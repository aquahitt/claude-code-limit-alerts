import type { EngineInterface, PluginOptions, Register } from 'claude-code'

import { fromCache, fromRateLimits, parseOffset, renderReport, type Cache, type Lang, type Report } from './format'

const CACHE_FILE = 'usage-monitor-cache.json'
const BACKOFF_FILE = 'usage-monitor-backoff.json'

// mtime of a file, or undefined when it is not there (fs.stat rejects).
async function mtime($: EngineInterface, path: string): Promise<number | undefined> {
  try {
    const stat = await $.fs.stat(path)
    return stat.kind === 'file' ? stat.mtimeMs : undefined
  } catch {
    return undefined
  }
}

// The monitor's state directory, by the same chain as the bash scripts:
// explicit option, UM_STATE_DIR, the classic install's ~/.claude/scripts.
// CLAUDE_PLUGIN_DATA is deliberately absent (see CLAUDE.md); the plugin
// install's data directory is found by name instead.
async function locate($: EngineInterface, options: PluginOptions): Promise<string | undefined> {
  const explicit = typeof options.state_dir === 'string' ? options.state_dir.trim() : ''
  if (explicit) {
    return explicit
  }

  const fromEnv = await $.env.get('UM_STATE_DIR')
  if (fromEnv) {
    return fromEnv
  }

  const home = await $.env.get('HOME')
  if (!home) {
    return undefined
  }

  const classic = `${home}/.claude/scripts`
  if ((await mtime($, `${classic}/${CACHE_FILE}`)) !== undefined) {
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
    const candidate = `${dataRoot}/${entry.name}`
    if ((await mtime($, `${candidate}/${CACHE_FILE}`)) !== undefined) {
      return candidate
    }
  }

  return undefined
}

async function readJson<T>($: EngineInterface, path: string): Promise<T | undefined> {
  try {
    return JSON.parse(await $.fs.read(path)) as T
  } catch {
    return undefined
  }
}

// The worker has no reliable local time zone, so the host's own `date` says
// it, once per report.
async function zoneOffset($: EngineInterface): Promise<number> {
  try {
    const { exitCode, stdout } = await $.process.run(['date', '+%z'], { timeoutMs: 2000 })
    return exitCode === 0 ? parseOffset(stdout) : 0
  } catch {
    return 0
  }
}

async function buildReport($: EngineInterface, options: PluginOptions): Promise<string> {
  const lang: Lang = options.lang === 'en' ? 'en' : 'ru'
  const thresholds = {
    warn: typeof options.warn === 'number' ? options.warn : 80,
    crit: typeof options.crit === 'number' ? options.crit : 95,
  }
  const now = await $.clock.now()

  // 5h/7d: this session's last API response wins, being current; the
  // monitor's cache fills in the scoped weekly limit, and 5h/7d before the
  // session has talked to the API.
  const live = fromRateLimits((await $.session.usage()).rateLimits)
  const report: Report = { source: 'none' }
  if (live.five && live.seven) {
    report.five = live.five
    report.seven = live.seven
    report.source = 'session'
  }

  const dir = await locate($, options)
  if (dir) {
    const cachePath = `${dir}/${CACHE_FILE}`
    const cacheMtime = await mtime($, cachePath)
    const cache = cacheMtime === undefined ? undefined : await readJson<Cache>($, cachePath)
    if (cache && cacheMtime !== undefined) {
      const cached = fromCache(cache)
      report.cacheAgeMs = Math.max(0, now - cacheMtime)
      report.scoped = cached.scoped
      if (report.source === 'none' && cached.five && cached.seven) {
        report.five = cached.five
        report.seven = cached.seven
        report.source = 'cache'
      }
    }
    const backoff = await readJson<{ until?: number }>($, `${dir}/${BACKOFF_FILE}`)
    if (typeof backoff?.until === 'number') {
      report.pausedUntil = backoff.until
    }
  }

  return renderReport(report, lang, thresholds, now, await zoneOffset($))
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)

    // Versions up to 0.1.0 pinned a status row. A pinned row is the host's and
    // survives a reload of this module, so clear it, or the last numbers the
    // old version drew stay on screen, frozen.
    $.ui.status(undefined)

    // immediate: the report reads no turn state, so it may run mid-turn
    // instead of queueing behind it.
    await $.command.register({
      name: 'limits',
      description: options.lang === 'en'
        ? 'Usage limits now: every window, reset times, where the numbers come from'
        : 'Лимиты сейчас: все окна, время сброса, откуда данные',
      immediate: true,
    })

    return result
  })

  // Answered here, as a transcript line: no model turn, no tokens.
  on('command.run', { command: 'limits' }, async $ => ({ text: await buildReport($, options) }))
}
