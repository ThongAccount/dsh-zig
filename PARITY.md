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
| CLI args | `cli.args.profile-shorthand` | PASS | PASS | implemented |
| CLI args | `cli.args.profile-with-patches` | PASS | PASS | implemented |
| CLI args | `cli.args.from-default-profile` | PASS | PASS | implemented |
| CLI args | `cli.args.app-flags-pass-through` | PASS | PASS | implemented |
| CLI args | `cli.args.web-help-passthrough` | PASS | PASS | implemented |
| CLI args | `cli.args.headless-positional` | PASS | PASS | implemented |
| CLI args | `cli.args.late-patch-belongs-to-app` | PASS | PASS | implemented |
| CLI args | `cli.args.dump-config` | PASS | PASS | implemented |
| CLI args | `cli.args.dump-default-config` | PASS | PASS | implemented |
| CLI args | `cli.args.dump-config-schema` | PASS | PASS | implemented |
| CLI args | `cli.args.plugin-forwarding` | PASS | PASS | implemented |
| CLI args | `cli.args.version-flag` | PASS (exit 0) | PASS | implemented |
| CLI args | `cli.args.reject-missing-profile` | PASS (exit 1) | PASS | implemented |
| CLI args | `cli.args.reject-competing-dumps` | PASS (exit 1) | PASS | implemented |
| CLI args | `cli.args.reject-desktop-profile` | PASS (exit 1) | PASS | implemented |
| CLI args | `cli.args.help-flag` | PASS (exit 0) | PASS | implemented |
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
| Agent tool pairing | `agent.tool-pairing.closed-step-balanced` | PASS | PASS | implemented |
| Agent tool pairing | `agent.tool-pairing.open-call-unbalanced` | PASS | PASS | implemented |
| Agent tool pairing | `agent.tool-pairing.multiple-calls-require-all-results` | PASS | PASS | implemented |
| Agent tool pairing | `agent.tool-pairing.neutral-node-crosses-open-pair` | PASS | PASS | implemented |
| Agent tool pairing | `agent.tool-pairing.missing-seq-throws` | PASS | PASS | implemented |
| Agent tool pairing | `agent.tool-pairing.orphan-result-throws` | PASS | PASS | implemented |
| Web server route | `web.route.select-exact-wins` | PASS | PASS | implemented |
| Web server route | `web.route.select-longest-prefix-wins` | PASS | PASS | implemented |
| Web server route | `web.route.select-prefix-own-path` | PASS | PASS | implemented |
| Web server route | `web.route.select-fallback-404` | PASS | PASS | implemented |
| Web server route | `web.route.dup-throws` | PASS (exit 1) | PASS | implemented |
| Web server upgrade | `web.upgrade.select` | PASS | PASS | implemented |
| Web server upgrade | `web.upgrade.select-miss` | PASS | PASS | implemented |
| Web server upgrade | `web.upgrade.dup-throws` | PASS (exit 1) | PASS | implemented |
| Web server gzip | `web.gzip.eligible` | PASS | PASS | implemented |
| Web server gzip | `web.gzip.below-threshold` | PASS | PASS | implemented |
| Web server gzip | `web.gzip.event-stream-never` | PASS | PASS | implemented |
| Web server gzip | `web.gzip.no-accept-encoding` | PASS | PASS | implemented |
| Web server host | `web.host.check-allowed` | PASS | PASS | implemented |
| Web server host | `web.host.check-rejected` | PASS | PASS | implemented |
| Web server host | `web.host.check-zero-port-form` | PASS | PASS | implemented |
| Web server auth | `web.auth.basic-ok` | PASS | PASS | implemented |
| Web server auth | `web.auth.basic-wrong` | PASS (exit 1) | PASS | implemented |
| Web server auth | `web.auth.basic-missing` | PASS (exit 1) | PASS | implemented |
| Web server static | `web.static.resolve` | PASS | PASS | implemented |
| Web server static | `web.static.traversal-rejected` | PASS (exit 1) | PASS | implemented |
| Web server index-injections | `web.index-injections.render` | PASS | PASS | implemented |

**Baseline: 32 pass, 15 expected-error cases. Total: 47 scenarios.**
**Slice 6 web server: +21 scenarios (route 5, upgrade 3, gzip 4, host 3, auth 3, static 2, index-injections 1). New total: 68 scenarios.**
**Slice 7 CLI args: +16 scenarios (profile boot, --patch, --from-default-profile, dump modes, plugin forwarding, version/help exit 0, missing-profile/competing-dumps/desktop reject exit 1, app-arg pass-through boundary).**
**Zig port: 68/68 implemented — FULL PARITY.** `tsx conformance/run-differential.mjs zig` → `68/68 match, 0 mismatch, 0 runner errors`. All slices complete per mission order: config, session JSONL, LLM SSE/retry, tool shell, agent tool-pairing, web server, CLI args.

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
