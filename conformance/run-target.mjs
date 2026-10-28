#!/usr/bin/env node
/**
 * Conformance target runner — executes a single scenario function from the
 * Node reference via tsx and prints the result as JSON to stdout.
 *
 * Usage:
 *   tsx conformance/run-target.mjs <scenario-id> [target]
 *
 * target = "node" (default): import the TS entry module from the reference
 *          checkout and call the scenario's function with the scenario input.
 *
 * The scenario definition is loaded from conformance/scenarios/<category>/<file>.json.
 * Each scenario declares target, entry module, function name, and per-case inputs.
 *
 * Output (one JSON line):
 *   { "caseId": "...", "ok": true, "output": <return value> }
 *   { "caseId": "...", "ok": false, "error": "<message>", "exitCode": <n> }
 *
 * For CLI scenarios (parseDshArgs calls process.exit), the case runs in a
 * child process so an exit does not kill the runner.
 */

import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const SELF = fileURLToPath(import.meta.url)
const CONFORMANCE_DIR = dirname(SELF)
const ORIGINAL = join(CONFORMANCE_DIR, '..', 'original')

function fail(message, code = 1) {
  console.error(message)
  process.exit(code)
}

const [scenarioId, target = 'node'] = process.argv.slice(2)
if (!scenarioId) fail('usage: tsx conformance/run-target.mjs <scenario-id> [target]')

const parts = scenarioId.split('.')
if (parts.length < 3) fail(`invalid scenario-id "${scenarioId}": expected <category>.<file>.<case>`)
const [category, fileName, ...caseParts] = parts
const caseId = caseParts.join('.')
const scenarioPath = join(CONFORMANCE_DIR, 'scenarios', category, fileName, `${fileName}.json`)

let scenario
try {
  scenario = JSON.parse(readFileSync(scenarioPath, 'utf8'))
} catch (error) {
  fail(`cannot read scenario ${scenarioPath}: ${error.message}`)
}

const cases = scenario.scenarios ?? []
const caseDef = cases.find(c => c.id === scenarioId)
if (!caseDef) fail(`scenario case "${scenarioId}" not found in ${scenarioPath}`)

async function main() {
  if (target === 'node') {
    await runNodeTarget(scenario, caseDef, scenarioId)
  } else if (target === 'zig') {
    await runZigTarget(scenarioId)
  } else {
    fail(`unknown target "${target}"`)
  }
}

async function runZigTarget(scenarioId) {
  const TSX = join(ORIGINAL, 'node_modules/tsx/dist/cli.mjs')
  const ZIG_TARGET = join(CONFORMANCE_DIR, 'zig-target.mjs')
  let raw
  try {
    raw = execFileSync(
      process.execPath, [TSX, ZIG_TARGET, scenarioId],
      { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }
    )
  } catch (error) {
    const stdout = error.stdout ? error.stdout.toString() : ''
    if (stdout.trim()) {
      // zig-target.mjs produced a result JSON even on non-zero exit; pass through.
      console.log(stdout.trim())
      return
    }
    fail(`zig target runner failed: ${error.message}`, 2)
  }
  console.log(raw.trim())
}

async function runNodeTarget(scenario, caseDef, caseId) {
  const entryPath = join(ORIGINAL, scenario.entry)
  let mod
  try {
    mod = await import(entryPath)
  } catch (error) {
    fail(`cannot import entry ${entryPath}: ${error.message}`, 2)
  }

  const fnName = scenario.function
  const fn = mod[fnName]
  if (typeof fn !== 'function') {
    fail(`function ${fnName} not exported from ${entryPath}`, 2)
  }

  const input = caseDef.input ?? {}
  let result, ok = true, errorMessage, exitCode

  try {
    // Config dump scenarios read the base config from a file path; if the
    // scenario provided inline content, materialize it to a temp file first.
    if (scenario.category === 'config' && typeof input.base === 'string') {
      const { mkdtempSync, writeFileSync } = await import('node:fs')
      const { tmpdir } = await import('node:os')
      const { join: pathJoin } = await import('node:path')
      const tmpDir = mkdtempSync(pathJoin(tmpdir(), 'dsh-conf-'))
      const basePath = pathJoin(tmpDir, 'base.yml')
      writeFileSync(basePath, input.base)
      input.base = basePath
      input.__tmpDir = tmpDir
    }

    if (scenario.category === 'config') {
      result = fn('dsh-test-bin', input.base, input.layers)
    } else if (scenario.category === 'cli' && fnName === 'parseDshArgs') {
      // CLI arg parsing may call process.exit → run in a child process.
      const payload = JSON.stringify({ argv: input.argv, version: input.version ?? '0.0.0' })
      const wrapper = join(ORIGINAL, 'conformance-cli-wrapper.mjs')
      const { mkdtempSync, writeFileSync, readFileSync, rmSync } = await import('node:fs')
      const { tmpdir } = await import('node:os')
      const { join: pathJoin } = await import('node:path')
      const tmpDir = mkdtempSync(pathJoin(tmpdir(), 'dsh-cli-'))
      const payloadPath = pathJoin(tmpDir, 'payload.json')
      const resultPath = pathJoin(tmpDir, 'result.json')
      writeFileSync(payloadPath, payload)
      try {
        execFileSync(
          process.execPath, [join(ORIGINAL, 'node_modules/tsx/dist/cli.mjs'), wrapper, payloadPath, resultPath],
          { cwd: ORIGINAL, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }
        )
      } catch {
        // execFileSync throws on non-zero exit; the result file still has our JSON.
      }
      const wrapped = JSON.parse(readFileSync(resultPath, 'utf8'))
      rmSync(tmpDir, { recursive: true, force: true })
      // The wrapper already emits { ok, output } or { ok, error, exitCode }.
      ok = wrapped.ok
      if (wrapped.ok) { result = wrapped.output }
      else { errorMessage = wrapped.error; exitCode = wrapped.exitCode }
    } else if (scenario.category === 'session') {
      // toHeaderLine(header, inheritedEventCount?) — separate args.
      result = fn(input.header, input.inheritedEventCount)
    } else if (scenario.category === 'llm' && fnName === 'providerError') {
      // providerError(raw, status, headers?)
      const headers = input.headers ? new Headers(input.headers) : undefined
      result = fn(input.raw ?? { error: { code: input.code, message: input.message } }, input.status, headers)
    } else if (scenario.category === 'llm' && fnName === 'parseSse') {
      // parseSse(body: ReadableStream, activity) — build a byte stream with
      // proper SSE framing (double-newline between events).
      const frames = input.frames ?? []
      const activityCalls = []
      const body = new ReadableStream({
        start(controller) {
          for (const frame of frames) {
            controller.enqueue(new TextEncoder().encode(frame + '\n\n'))
          }
          controller.close()
        }
      })
      result = []
      for await (const event of fn(body, () => { activityCalls.push() })) {
        result.push(event)
      }
      result = { events: result, activityCalls: activityCalls.length }
    } else {
      result = await fn(input)
    }
  } catch (error) {
    ok = false
    errorMessage = error instanceof Error ? error.message : String(error)
    exitCode = error.exitCode
  }

  if (!ok) {
    console.log(JSON.stringify({ caseId: caseId, ok: false, error: errorMessage, exitCode }))
  } else {
    console.log(JSON.stringify({ caseId: caseId, ok: true, output: result }))
  }
}

main().catch(error => fail(`runner failure: ${error.message}`, 2))
