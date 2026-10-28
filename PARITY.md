# PARITY.md — DSH Zig Port Conformance Status

Living table tracking which behaviors of the Node reference (`dsh-v0.2.0-rc.2`,
commit `639ed01539`) are covered by the conformance harness, and whether the
Zig port matches them. Updated by Toolsmith as slices land.

## Source of truth

- **Reference checkout:** `/workspace/dsh-zig/original` (tag `dsh-v0.2.0-rc.2`, commit `639ed01539`)
- **Conformance harness:** `/workspace/dsh-zig/conformance/`
- **Golden fixtures:** `/workspace/dsh-zig/conformance/fixtures/` — one JSON per scenario case, extracted from the Node reference
- **CI:** `.github/workflows/conformance.yml`

## How to read this table

| Column | Meaning |
|---|---|
| Area | Subsystem being ported |
| Scenario | Conformance scenario case ID |
| Reference | Node reference result (PASS = produces expected output) |
| Zig port | Zig port result (blank = not yet implemented) |
| Status | `covered` = harness has a scenario; `implemented` = Zig port matches fixture |

## Conformance coverage (Phase 1 baseline)

| Area | Scenario | Reference | Zig port | Status |
|---|---|---|---|---|
| CLI args | `cli.args.profile-shorthand` | PASS | | covered |
| CLI args | `cli.args.profile-with-patches` | PASS | | covered |
| CLI args | `cli.args.from-default-profile` | PASS | | covered |
| CLI args | `cli.args.app-flags-pass-through` | PASS | | covered |
| CLI args | `cli.args.web-help-passthrough` | PASS | | covered |
| CLI args | `cli.args.headless-positional` | PASS | | covered |
| CLI args | `cli.args.late-patch-belongs-to-app` | PASS | | covered |
| CLI args | `cli.args.dump-config` | PASS | | covered |
| CLI args | `cli.args.dump-default-config` | PASS | | covered |
| CLI args | `cli.args.dump-config-schema` | PASS | | covered |
| CLI args | `cli.args.plugin-forwarding` | PASS | | covered |
| CLI args | `cli.args.version-flag` | PASS (exit 0) | | covered |
| CLI args | `cli.args.reject-missing-profile` | PASS (exit 1) | | covered |
| CLI args | `cli.args.reject-competing-dumps` | PASS (exit 1) | | covered |
| CLI args | `cli.args.reject-desktop-profile` | PASS (exit 1) | | covered |
| CLI args | `cli.args.help-flag` | PASS (exit 0) | | covered |
| Config patch layering | `config.patch-layering.compose-layers-in-order` | PASS | PASS | implemented |
| Config patch layering | `config.patch-layering.js-expr-verbatim` | PASS | PASS | implemented |
| Config patch layering | `config.patch-layering.source-separators` | PASS | PASS | implemented |
| Config slice 1 | `config.slice1.load` | PASS | PASS | implemented |
| Config slice 1 | `config.slice1.apply` | PASS | PASS | implemented |
| Session JSONL | `session.jsonl.header-line-format` | PASS | PASS | implemented |
| Session JSONL | `session.jsonl.header-no-cwd` | PASS | PASS | implemented |
| Session JSONL | `session.jsonl.header-seeded-requires-count` | PASS (throws) | PASS | implemented |
| Session JSONL | `session.jsonl.header-unnseeded-with-count` | PASS (throws) | PASS | implemented |
| LLM SSE | `llm.sse.text-chunk-events` | PASS | PASS | implemented |
| LLM SSE | `llm.sse.message-stop-signal` | PASS | PASS | implemented |
| LLM SSE | `llm.sse.error-frame` | PASS (throws) | PASS | implemented |
| LLM SSE | `llm.sse.event-type-mismatch` | PASS (throws) | PASS | implemented |
| LLM SSE | `llm.sse.invalid-json` | PASS (throws) | PASS | implemented |
| LLM SSE | `llm.sse.heartbeat-comment` | PASS | PASS | implemented |
| LLM retry | `llm.retry.transient-failure-retries` | PASS | PASS | implemented |
| LLM retry | `llm.retry.permanent-failure-fails-fast` | PASS | PASS | implemented |
| LLM retry | `llm.retry.rate-limit-backoff` | PASS | PASS | implemented |
| LLM retry | `llm.retry.sse-stream-error` | PASS | PASS | implemented |
| LLM retry | `llm.retry.exhausted-attempts` | PASS | PASS | implemented |
| Tool shell | `tool.shell.echo-hello` | PASS | PASS | implemented |
| Tool shell | `tool.shell.exit-code` | PASS | PASS | implemented |
| Tool shell | `tool.shell.stderr` | PASS | PASS | implemented |
| Tool shell | `tool.shell.stdout-stderr` | PASS | PASS | implemented |
| Tool shell | `tool.shell.empty-output` | PASS | PASS | implemented |

**Baseline: 32 pass, 9 expected-error cases. Total: 41 scenarios.**
**Zig port: 25/41 implemented (slice 1 config: load + apply, patch-layering; slice 2 session: jsonl header format; slice 3 LLM: SSE event parsing + retry/backoff/error paths; slice 4 tool runtime: shell command execution via spawn). Remaining: cli.args (16 scenarios, last slice per mission order).**

## Adding a scenario

1. Add a case to `conformance/scenarios/<category>/<file>.json` (declare `target`, `entry`, `function`, `scenarios[].input`/`expected`).
2. Run `tsx conformance/extract-fixtures.mjs` to regenerate golden fixtures.
3. Run `tsx conformance/run-differential.mjs node` — all 34 must match.
4. Update this table.

## How the Zig port proves parity

When a Zig target exists (`conformance/zig-target.mjs`), run:

```
tsx conformance/run-differential.mjs zig
```

Each scenario case runs against the Zig port and its output is deep-compared
to the golden fixture. Exit 0 = all 34 match. Any mismatch fails CI.
