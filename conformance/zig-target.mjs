#!/usr/bin/env node
/**
 * Zig port conformance target.
 *
 * Builds the Zig port (`zig build`) and runs a single conformance scenario
 * against the built binary, printing one JSON result line to stdout.
 *
 * Usage:
 *   tsx conformance/zig-target.mjs <scenario-id>
 *   DSH_ZIG=/path/to/zig DSH_BIN=/path/to/binary tsx conformance/zig-target.mjs cli.args.version-flag
 *
 * Output contract (same as conformance/run-target.mjs for the node target):
 *   { "caseId": "...", "ok": true, "output": <value> }
 *   { "caseId": "...", "ok": false, "error": "<message>", "exitCode": <n> }
 *
 * Zig binary contract (implemented by the port, slice 1+):
 *   dsh conformance <scenario-id> <input-json-file>
 *   Reads the scenario input from <input-json-file> and prints one result JSON
 *   line to stdout. Exits 0 when a result JSON is produced — scenario errors
 *   (invalid args, rejection, SSE parse failure, …) are carried inside the JSON
 *   as { ok: false, error, exitCode }. The binary exits non-zero only on
 *   internal failure.
 *
 * This runner exits 0 whenever it produces a result JSON (so the differential
 * runner can compare it to the golden fixture). It exits non-zero only when the
 * Zig binary cannot be built or located — a runner-level failure that the
 * differential runner reports as RUNNER-ERROR, which is honest while the port
 * is not yet implemented.
 */

import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'

const SELF = fileURLToPath(import.meta.url)
const CONFORMANCE_DIR = dirname(SELF)
const REPO_ROOT = join(CONFORMANCE_DIR, '..')
const SCENARIOS_DIR = join(CONFORMANCE_DIR, 'scenarios')

const DEFAULT_ZIG = '/workspace/tools/bin/zig'
// Local dev uses the pinned toolchain under /workspace/tools; CI (setup-zig)
// puts `zig` on PATH, so fall back to PATH when the pinned path is absent.
const ZIG = process.env.DSH_ZIG || (existsSync(DEFAULT_ZIG) ? DEFAULT_ZIG : 'zig')
// Candidate locations for the port binary (SysLead names it in build.zig).
const BINARY_CANDIDATES = process.env.DSH_BIN
  ? [process.env.DSH_BIN]
  : [join(REPO_ROOT, 'zig-out', 'bin', 'dsh'), join(REPO_ROOT, 'zig-out', 'bin', 'dsh-zig')]

const [scenarioId] = process.argv.slice(2)
if (!scenarioId) {
  console.error('usage: tsx conformance/zig-target.mjs <scenario-id>')
  process.exit(2)
}

function fail(message, code = 1) {
  console.error(message)
  process.exit(code)
}

function findBinary() {
  return BINARY_CANDIDATES.find(b => existsSync(b))
}

function loadCase(scenarioId) {
  const parts = scenarioId.split('.')
  if (parts.length < 3) {
    fail(`invalid scenario-id "${scenarioId}": expected <category>.<file>.<case>`, 2)
  }
  const [category, fileName, ...caseParts] = parts
  const caseId = caseParts.join('.')
  const scenarioPath = join(SCENARIOS_DIR, category, fileName, `${fileName}.json`)
  let scenario
  try {
    scenario = JSON.parse(readFileSync(scenarioPath, 'utf8'))
  } catch (error) {
    fail(`cannot read scenario ${scenarioPath}: ${error.message}`, 2)
  }
  const caseDef = scenario.scenarios.find(c => c.id === scenarioId)
  if (!caseDef) {
    fail(`scenario case "${scenarioId}" not found in ${scenarioPath}`, 2)
  }
  return { caseId, caseDef }
}

function ensureBinary() {
  if (findBinary()) return
  try {
    execFileSync(ZIG, ['build'], { cwd: REPO_ROOT, encoding: 'utf8', stdio: 'pipe' })
  } catch (error) {
    const hint = error.stderr ? error.stderr.toString().trim().split('\n').slice(-3).join(' ') : error.message
    fail(`cannot build Zig port binary: ${hint}`, 2)
  }
  if (!findBinary()) {
    fail(`zig build ran but produced no binary at ${BINARY_CANDIDATES.join(' or ')}`, 2)
  }
}

function runScenario(binary, scenarioId, input) {
  const tmpDir = mkdtempSync(join(tmpdir(), 'dsh-zig-conf-'))
  const inputPath = join(tmpDir, 'input.json')
  writeFileSync(inputPath, JSON.stringify(input))
  try {
    try {
      const raw = execFileSync(
        binary, ['conformance', scenarioId, inputPath],
        { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }
      )
      try {
        return normalize(JSON.parse(raw.trim()), scenarioId)
      } catch (parseError) {
        console.error('DEBUG parse error:', parseError.message)
        console.error('DEBUG raw was:', JSON.stringify(raw))
        throw parseError
      }
    } catch (error) {
      const stdout = error.stdout ? error.stdout.toString() : ''
      let parsed
      try { parsed = JSON.parse(stdout.trim()) } catch { parsed = null }
      if (parsed) {
        // Binary produced a result JSON despite non-zero exit; pass it through.
        return normalize(parsed, scenarioId)
      }
      const code = error.exitCode ?? 1
      return { caseId: scenarioId, ok: false, error: `zig binary exited ${code}: ${error.message}`, exitCode: code }
    }
  } finally {
    rmSync(tmpDir, { recursive: true, force: true })
  }
}

function normalize(result, scenarioId) {
  if (!result || typeof result !== 'object') {
    return { caseId: scenarioId, ok: false, error: 'zig binary returned non-JSON output', exitCode: 1 }
  }
  if (!result.caseId) result.caseId = scenarioId
  if (typeof result.ok !== 'boolean') result.ok = !!result.ok
  return result
}

function main() {
  const { caseId, caseDef } = loadCase(scenarioId)
  const input = caseDef.input ?? {}

  ensureBinary() // exits 2 if the port cannot be built yet (runner-level failure)
  const binary = findBinary()

  const result = runScenario(binary, scenarioId, input)
  console.log(JSON.stringify(result))
}

main()
