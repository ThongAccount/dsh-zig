/**
 * One-shot web server decision logic for conformance testing of the Zig port.
 *
 * Every exported operation is pure (no listening sockets), so a single
 * `dsh conformance <case> <input.json>` invocation produces one deterministic
 * JSON result. Mirrors the semantics of @deepseek-ai/dsh-host-webserver and
 * @deepseek-ai/dsh-api-gateway in the Node reference:
 *
 *   - exact routes beat prefix routes; longest prefix wins; prefix matches its
 *     own path; no match → null (fallback seat / 404)
 *   - duplicate (kind, path) or duplicate upgrade path throws
 *   - gzip: never for text/event-stream, never below the 1024-byte threshold,
 *     otherwise gzip when Accept-Encoding contains `gzip`
 *   - host check: only the two configured bind hosts pass (127.0.0.1, 0.0.0.0);
 *     a hostname before an optional `:port` is validated
 *   - basic auth: missing/wrong credentials → 401 with `Basic` challenge
 *   - static assets: exact URL-path match against the embedded asset table;
 *     percent-decoded `..` segments → traversal rejection
 *   - index injections: structured rows rendered into index.html (delegates to
 *     the Node reference's pure `renderIndexInjections`)
 *
 * Input:  { op: string, ...op-specific fields }
 * Output: op-specific JSON value, or throws { message, exitCode } for
 *         expected-error cases (401 unauthorized, 1 misconfiguration).
 */

import { renderIndexInjections } from '../original/packages/host/webserver/src/injections.ts'

const GZIP_THRESHOLD_BYTES = 1024

function hasEncoding(acceptEncoding: string | null | undefined, encoding: string): boolean {
  if (!acceptEncoding) return false
  return acceptEncoding.split(',').map(part => part.trim()).some(part => part === encoding)
}

function hostnameOf(host: string): string {
  const at = host.indexOf(':')
  return at === -1 ? host : host.slice(0, at)
}

function hasTraversal(urlPath: string): boolean {
  const decoded = decodeURIComponentSafe(urlPath)
  const segments = decoded.split('/')
  return segments.some(segment => segment === '..')
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s)
  } catch {
    return s
  }
}

function duplicatePath(entries: { path: string }[]): string | undefined {
  const seen = new Set<string>()
  for (const entry of entries) {
    if (seen.has(entry.path)) return entry.path
    seen.add(entry.path)
  }
  return undefined
}

function fail(message: string, exitCode: number): never {
  const error = new Error(message) as Error & { exitCode?: number }
  error.exitCode = exitCode
  throw error
}

export function runWebOp(input: {
  op: string
  routes?: { kind: string; path: string }[]
  upgrades?: { path: string }[]
  pathname?: string
  contentType?: string | null
  contentLength?: number | null
  acceptEncoding?: string | null
  host?: string
  authorization?: string | null
  expectedUser?: string
  expectedPass?: string
  assets?: { url: string; path: string }[]
  urlPath?: string
  html?: string
  rows?: unknown[]
}): unknown {
  const op = input.op

  // ---- HTTP route selection -----------------------------------------------
  if (op === 'web.route.select') {
    const routes = input.routes ?? []
    const pathname = input.pathname ?? ''
    let exact: { kind: string; path: string } | undefined
    for (const route of routes) {
      if (route.kind === 'exact' && route.path === pathname) {
        exact = route
        break
      }
    }
    if (exact) return { matched: { kind: 'exact', path: exact.path } }
    let best: { kind: string; path: string } | undefined
    for (const route of routes) {
      if (route.kind !== 'prefix') continue
      if (pathname !== route.path && !pathname.startsWith(route.path + '/')) continue
      if (best === undefined || route.path.length > best.path.length) best = route
    }
    return { matched: best ? { kind: 'prefix', path: best.path } : null }
  }

  if (op === 'web.route.dup-throws') {
    const routes = input.routes ?? []
    const dup = duplicatePath(routes)
    if (dup !== undefined) fail(`webserver: duplicate exact route "${dup}"`, 1)
    return { ok: true }
  }

  // ---- WebSocket upgrade selection ----------------------------------------
  if (op === 'web.upgrade.select') {
    const upgrades = input.upgrades ?? []
    const pathname = input.pathname ?? ''
    for (const route of upgrades) {
      if (route.path === pathname) return { matched: { path: route.path } }
    }
    return { matched: null }
  }

  if (op === 'web.upgrade.dup-throws') {
    const upgrades = input.upgrades ?? []
    const dup = duplicatePath(upgrades)
    if (dup !== undefined) fail(`webserver: duplicate upgrade route "${dup}"`, 1)
    return { ok: true }
  }

  // ---- gzip eligibility ----------------------------------------------------
  if (op === 'web.gzip.decision') {
    const contentType = input.contentType ?? ''
    const contentLength = input.contentLength
    const acceptEncoding = input.acceptEncoding ?? ''
    if (contentType === 'text/event-stream') return { encoding: 'identity' }
    if (typeof contentLength === 'number' && contentLength < GZIP_THRESHOLD_BYTES) {
      return { encoding: 'identity' }
    }
    return { encoding: hasEncoding(acceptEncoding, 'gzip') ? 'gzip' : 'identity' }
  }

  // ---- host check ----------------------------------------------------------
  if (op === 'web.host.check') {
    const allowed = hostnameOf(input.host ?? '') === '127.0.0.1' ||
      hostnameOf(input.host ?? '') === '0.0.0.0'
    return { allowed }
  }

  // ---- basic auth ----------------------------------------------------------
  if (op === 'web.auth.basic') {
    const authorization = input.authorization ?? null
    if (authorization === null || !/^Basic\s/i.test(authorization as string)) {
      fail('unauthorized', 401)
    }
    const encoded = (authorization as string).replace(/^Basic\s/i, '').trim()
    let credentials: string
    try {
      credentials = Buffer.from(encoded, 'base64').toString('utf8')
    } catch {
      fail('unauthorized', 401)
    }
    const colon = credentials.indexOf(':')
    const user = colon === -1 ? credentials : credentials.slice(0, colon)
    const pass = colon === -1 ? '' : credentials.slice(colon + 1)
    if (user === input.expectedUser && pass === input.expectedPass) {
      return { authenticated: true }
    }
    fail('unauthorized', 401)
  }

  // ---- embedded static assets ----------------------------------------------
  if (op === 'web.static.resolve') {
    const urlPath = input.urlPath ?? ''
    if (hasTraversal(urlPath)) fail('traversal', 1)
    const assets = input.assets ?? []
    for (const asset of assets) {
      if (asset.url === urlPath) return { assetPath: asset.path }
    }
    return { assetPath: null }
  }

  // ---- index-injection rendering (Node reference: renderIndexInjections) ---
  if (op === 'web.index-injections.render') {
    const html = typeof input.html === 'string' ? input.html : ''
    const rows = Array.isArray(input.rows) ? input.rows : []
    return renderIndexInjections(html, rows as never[])
  }

  fail(`unknown web op: ${op}`, 2)
}
