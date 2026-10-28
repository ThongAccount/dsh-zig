#!/usr/bin/env node
/**
 * Golden fixture extraction — runs every conformance scenario against the Node
 * reference and writes the results to conformance/fixtures/<category>/<file>/<case>.json.
 *
 * Usage:
 *   tsx conformance/extract-fixtures.mjs
 *
 * Each fixture file contains:
 *   { "caseId": "...", "ok": <bool>, "output": <any> | { "error": "...", "exitCode": <n> } }
 *
 * These fixtures are the baseline: the Zig port must produce identical output
 * for every case. The differential runner (run-differential.mjs) compares port
 * output against these fixtures.
 */

import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const SELF = fileURLToPath(import.meta.url)
const CONFORMANCE_DIR = dirname(SELF)
const ORIGINAL = join(CONFORMANCE_DIR, '..', 'original')
const FIXTURES_DIR = join(CONFORMANCE_DIR, 'fixtures')
const SCENARIOS_DIR = join(CONFORMANCE_DIR, 'scenarios')
const TSX = join(ORIGINAL, 'node_modules/tsx/dist/cli.mjs')

function walkScenarios(dir) {
  const results = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) results.push(...walkScenarios(full))
    else if (entry.name.endsWith('.json')) results.push(full)
  }
  return results
}

async function main() {
  const scenarioFiles = walkScenarios(SCENARIOS_DIR)
  let passed = 0, failed = 0

  for (const scenarioFile of scenarioFiles) {
    const scenario = JSON.parse(readFileSync(scenarioFile, 'utf8'))
    const category = scenario.category
    const fileBase = scenarioFile.split('/').pop().replace('.json', '')

    for (const caseDef of scenario.scenarios) {
      const caseId = caseDef.id
      const [cat, fileName, ...caseParts] = caseId.split('.')
      const shortCaseId = caseParts.join('.')

      // Build the runner invocation
      const runner = join(CONFORMANCE_DIR, 'run-target.mjs')
      let output
      try {
        const raw = execFileSync(
          process.execPath, [TSX, runner, caseId, 'node'],
          { cwd: ORIGINAL, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }
        )
        output = JSON.parse(raw.trim())
      } catch (error) {
        // execFileSync may throw on non-zero exit from the child; the child
        // still prints its JSON to stdout before exiting.
        output = { caseId, ok: false, error: `runner failure: ${error.message}` }
      }

      // Normalize: success cases carry `output`, error cases carry `error`+`exitCode`
      const fixture = {
        caseId,
        ok: output.ok,
        ...(output.ok ? { output: output.output } : { error: output.error, exitCode: output.exitCode })
      }

      // Write fixture
      const fixtureDir = join(FIXTURES_DIR, category, fileBase)
      mkdirSync(fixtureDir, { recursive: true })
      writeFileSync(join(fixtureDir, `${shortCaseId}.json`), JSON.stringify(fixture, null, 2) + '\n')

      if (output.ok) passed += 1
      else failed += 1
      console.log(`${caseId}: ${output.ok ? 'PASS' : 'FAIL (expected error)'}`)
    }
  }

  console.log(`\nBaseline: ${passed} pass, ${failed} expected-error cases. Total: ${passed + failed} scenarios.`)
}

main().catch(error => { console.error(error); process.exit(1) })
