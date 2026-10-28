/**
 * Minimal spawn wrapper for conformance testing of the Zig tool runtime.
 *
 * Runs a command synchronously and returns stdout/stderr/exitCode.
 * Used by the conformance harness's Node target for tool.shell.* scenarios.
 *
 * Input:  { argv: string[], cwd?: string | null }
 * Output: { stdout: string, stderr: string, exitCode: number | null }
 */
import { spawnSync as nodeSpawnSync } from 'node:child_process'

export function spawnSync(input: {
  argv: string[]
  cwd?: string | null
}): { stdout: string; stderr: string; exitCode: number | null } {
  const result = nodeSpawnSync(input.argv[0], input.argv.slice(1), {
    cwd: input.cwd ?? undefined,
    encoding: 'utf8',
  })
  return {
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    exitCode: result.status,
  }
}
