#!/usr/bin/env node
/**
 * Differential conformance runner — compares a target's output against golden
 * fixtures extracted from the Node reference.
 *
 * Usage:
 *   tsx conformance/run-differential.mjs <target>
 *
 * target = "node" : run against the Node reference (validates the harness itself;
 *   every case should match its golden fixture)
 * target = "zig"  : run against the Zig port (the real conformance check;
 *   requires the Zig port binary to be built and available)
 *
 * For each scenario case, the runner:
 *   1. Loads the golden fixture from conformance/fixtures/<category>/<file>/<case>.json
 *   2. Runs the scenario against the target via conformance/run-target.mjs
 *   3. Compares target output to the golden fixture (deep equality for success
 *      cases; error/exitCode match for failure cases)
 *   4. Reports PASS/MISMATCH with a diff
 *
 * Exit code: 0 if all cases match, 1 if any mismatch.
 */

import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const SELF = fileURLToPath(import.meta.url)
const CONFORMANCE_DIR = dirname(SELF)
const FIXTURES_DIR = join(CONFORMANCE_DIR, 'fixtures')
const RUNNER = join(CONFORMANCE_DIR, 'run-target.mjs')
const ORIGINAL = join(CONFORMANCE_DIR, '..', 'original')
const TSX = join(ORIGINAL, 'node_modules/tsx/dist/cli.mjs')

function walkFixtures(dir) {
  const results = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) results.push(...walkFixtures(full))
    else if (entry.name.endsWith('.json')) results.push(full)
  }
  return results
}

function deepEqual(a, b) {
  if (a === b) return true
  if (typeof a !== typeof b) return false
  if (a === null || b === null || typeof a !== 'object') return false
  const ka = Object.keys(a), kb = Object.keys(b)
  if (ka.length !== kb.length) return false
  for (const k of ka) {
    if (!Object.hasOwn(b, k)) return false
    if (!deepEqual(a[k], b[k])) return false
  }
  return true
}

function diffSummary(a, b) {
  // Produce a human-readable one-line summary of the first difference.
  const seen = new Set()
  function walk(x, y, path) {
    if (x === y) return null
    if (typeof x !== typeof y || x === null || y === null || typeof x !== 'object') {
      return `${path || '<root>'}: ${JSON.stringify(x)} !== ${JSON.stringify(y)}`
    }
    const ka = Object.keys(x), kb = Object.keys(y)
    for (const k of ka) {
      const p = path ? `${path}.${k}` : k
      if (!Object.hasOwn(y, k)) return `${p}: missing in target`
      const d = walk(x[k], y[k], p)
      if (d) return d
    }
    for (const k of kb) {
      if (!Object.hasOwn(x, k)) return `${path ? `${path}.${k}` : k}: extra in target`
    }
    return null
  }
  return walk(a, b, '') || 'values differ'
}

async function main() {
  const target = process.argv[2]
  if (!target || !['node', 'zig'].includes(target)) {
    console.error('usage: tsx conformance/run-differential.mjs <node|zig>')
    process.exit(1)
  }

  const fixtureFiles = walkFixtures(FIXTURES_DIR)
  let passed = 0, mismatched = 0, errors = 0

  for (const fixtureFile of fixtureFiles) {
    const fixture = JSON.parse(readFileSync(fixtureFile, 'utf8'))
    const caseId = fixture.caseId

    // Run the scenario against the target
    let targetOutput
    try {
      const raw = execFileSync(
        process.execPath, [TSX, RUNNER, caseId, target],
        { cwd: ORIGINAL, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }
      )
      targetOutput = JSON.parse(raw.trim())
    } catch (error) {
      // execFileSync throws on non-zero exit; try to read stdout
      const stdout = error.stdout ? error.stdout.toString() : ''
      let parsed
      try { parsed = JSON.parse(stdout.trim()) } catch { parsed = null }
      targetOutput = parsed ?? { caseId, ok: false, error: `runner error: ${error.message}`, exitCode: 1 }
      errors += 1
      console.log(`${caseId}: RUNNER-ERROR (${error.message})`)
      continue
    }

    // Compare against golden fixture
    const match = deepEqual(fixture, targetOutput)
    if (match) {
      passed += 1
      console.log(`${caseId}: PASS`)
    } else {
      mismatched += 1
      console.log(`${caseId}: MISMATCH`)
      console.log(`  fixture: ${JSON.stringify(fixture)}`)
      console.log(`  target:  ${JSON.stringify(targetOutput)}`)
      console.log(`  diff: ${diffSummary(fixture, targetOutput)}`)
    }
  }

  const total = passed + mismatched + errors
  console.log(`\nDifferential result: ${passed}/${total} match, ${mismatched} mismatch, ${errors} runner errors.`)
  process.exit(mismatched > 0 || errors > 0 ? 1 : 0)
}

main().catch(error => { console.error(error); process.exit(1) })
