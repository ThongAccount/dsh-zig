# RISK.md — DSH Zig Port Risk Log

Risks identified during Phase 0 (port strategy) and Phase 1 (conformance
harness). Each risk is rated, owned, and has a mitigation or tracking issue.
Reviewed by Toolsmith at the start of each Phase 2 slice.

## Risk rating key

- **Critical:** blocks first useful release; no workaround.
- **High:** significant user-visible impact; needs a plan before the slice that touches it.
- **Medium:** contained impact; mitigate in-slice.
- **Low:** documented for awareness; no immediate action.

## Open risks

| ID | Area | Risk | Rating | Owner | Mitigation / status |
|---|---|---|---|---|---|
| R-001 | Config | `!!js` expressions in YAML config are dropped (Option C decision). Configs that use them break silently. | High | Toolsmith | Documented in ADR-001 as an explicit trade-off. Conformance harness captures `!!js` verbatim passthrough so the port at least preserves them textually. |
| R-002 | LLM | No Zig TLS client in std. DeepSeek API needs HTTPS; Zig std `std.crypto` is not a full TLS client. | Critical | Toolsmith | Vendor a C TLS library (mbedtls) or shell out to `openssl`; vendor C deps and record each version (engineering rule). |
| R-003 | LLM | SSE streaming semantics (eventsource-parser framing, heartbeat comments, malformed JSON) must match Node exactly. | High | Toolsmith | Conformance scenario `llm.sse.*` covers parsing, error frames, type mismatches, invalid JSON, heartbeats. Differential runner enforces byte-for-byte event parity. |
| R-004 | Session | JSONL + Zstandard persistence must be bit-compatible with the Node reference so sessions can be read/written by both. | High | Toolsmith | Conformance scenario `session.jsonl.*` covers header encoding and validation. Zstandard frame format is the compatibility surface. |
| R-005 | Config | Patch layering composition order (bundles → profile → home → --patch → telemetry) must match Node exactly. | High | Toolsmith | Conformance scenario `config.patch-layering.*` covers composition order, `!!js` verbatim, source separators. |
| R-006 | CLI | Argument parsing boundary (launcher flags vs app arguments) must match Node exactly. | Medium | Toolsmith | Conformance scenario `cli.args.*` covers pass-through, dump modes, plugin forwarding, rejections. |
| R-007 | Agent loop | Re-implementing turn boundaries, tool history, and compaction is subtle; semantic drift is the #1 source of production bugs. | High | Toolsmith | Differential testing against the Node reference is the only safety net (ADR-001). Slice 5 lands `agent.tool-pairing.*` (tool-call/result pairing balance at surface cuts) verified 6/6 via `run-differential.mjs zig`. Full `CompactionEngine` (summarization, lock brackets, `Session` mutation) remains Phase 2+ behind the same differential harness. |
| R-008 | Plugins | Cordis plugin system has no Zig equivalent; dynamic plugin installation is out of subset. | Medium | — | Explicitly deferred per ADR-001. Static plugin registry is the planned replacement. |
| R-009 | Native addons | Landlock sandboxing and POSIX flock are Node-API C addons. | Medium | SysLead | Replace with direct Zig syscalls (Landlock via std wrappers, flock via std.os.flock). Slice 4 tool runtime uses pure `std.process.run` (no C deps); sandbox Landlock/flock remains Phase 2+. |
| R-010 | Event loop | QuickJS (Option B) was rejected; Option C uses a custom Zig event loop. Bridging to any future JS engine is risky. | Medium | — | Option C avoids QuickJS entirely. Revisit if Option B is ever reconsidered. |
| R-011 | Web profile | User chose Web profile first (overrides headless suggestion). Web profile is the broadest surface; more to implement per slice. | Medium | Toolsmith | Conformance harness exercises the full stack early. Start with headless subset, grow to web. |
| R-012 | Profiling | Static binaries for linux x86_64 and aarch64; vendor C dependencies and record each version. | Low | SysLead | Engineering rule carried into Phase 2. Record versions in this log when vendored. |
| R-013 | Web server | HTTP route matching (exact vs longest-prefix, dup detection), basic-auth base64 decoding, gzip eligibility rules, static path traversal, index-injection placement must match Node exactly. | Medium | WebLead | Conformance scenarios `web.route.*`, `web.upgrade.*`, `web.gzip.*`, `web.host.*`, `web.auth.*`, `web.static.*`, `web.index-injections.*` (21 cases) verified via `run-differential.mjs zig` — slice 6 at parity, 21/21 web cases PASS. |

## Vendored C dependencies (recorded per engineering rule)

| Dependency | Version | Purpose | Status |
|---|---|---|---|
| (none yet) | — | — | Port not started |

## Non-portable items flagged early

| Item | Why non-portable | Disposition |
|---|---|---|
| `!!js` config expressions | No Zig JS engine in subset; dropping them is explicit | Documented in ADR-001; harness preserves verbatim |
| Node-API addons (landlock-run, flock) | Zig has no Node-API equivalent | Replace with direct syscalls (Phase 2+) |
| PTY / terminal | Platform-specific syscalls | Deferred to Phase 2+ |
| `structuredClone`, `AbortController`, `fetch` | Modern Node/Web APIs not in Zig std | Implement from scratch per slice |
| Electron desktop app | Not a Zig target | Out of scope per ADR-001 |
