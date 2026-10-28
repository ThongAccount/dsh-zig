# ADR-001: DSH Port Strategy to Zig

**Status:** Approved.  
**Source:** DSH `dsh-v0.2.0-rc.2` (commit `639ed01539`).  
**Decision:** Option C, Zig 0.17.0, Web profile first.  
**Deciders:** User (Chief coordinates).

## Context

Port DeepSeek Harness (DSH) from Node/TypeScript to Zig. The source is a ~61-package monorepo (~3,700 TS source files in packages/, ~522 in apps/) built on the Cordis plugin framework. Everything is a plugin: model adapters, tools, session log, agent loop, web server. Config uses YAML with `!!js` embedded JavaScript expressions. Profiles compose ordered patch layers (bundles → profile → home → `--patch` overlays → telemetry switch). Native C addons provide Landlock sandboxing (Linux) and POSIX flock. Session persistence is JSONL + Zstandard (no SQLite). CLI launcher owns env snapshot, proxy resolution, signal handling, and `DSH_HOME`.

## Option A: Full native rewrite

Replace every DSH subsystem with Zig code, including a replacement for the Cordis plugin system.

**Scope:** CLI, config/patch layering, session store (JSONL), LLM adapters + streaming, tool runtime (PTY, shell, sandbox), agent loop, web server (HTTP + WebSocket), plugin host, plugin manager.

**Costs:**
- Highest implementation effort: re-implement ~300k LOC of TypeScript semantics in Zig.
- Plugin system must be redesigned: Zig has no dynamic `require`/`import` equivalent for hot-reloaded modules; plugin loading needs a custom ABI or static registration.
- `!!js` config expressions have no direct equivalent — must drop or embed a JS engine (contradicts "full native").
- Node-API addons (landlock-run, flock) replaced by direct Zig syscalls (Landlock via `seccomp`-like Zig std wrappers, flock via `std.os.flock`).
- Electron desktop app and web frontend (React/Vite) are out of scope for a Zig rewrite — the port targets the CLI/headless surface primarily; web UI would need a separate Zig web server serving static assets.
- pnpm workspace and npm package publishing model replaced by Zig build.zig + Zig modules.

**Risks:**
- Semantic drift: subtle behaviors in Cordis (fiber lifecycle, HMR, patch write-back, `!!js` evaluation) are hard to replicate faithfully.
- No existing Zig ecosystem for LLM provider SDKs (DeepSeek API, SSE streaming, retry) — must write HTTP clients from scratch.
- Differential testing against the Node reference is the only safety net; gaps in coverage become production bugs.
- Longest time to first useful release.

**Leaves out:** `!!js` config expressions (dropped), Electron desktop app, HMR module hot-reload (replaced by static plugin registry), some niche plugins.

---

## Option B: Zig host embedding a JS engine (e.g. QuickJS)

A Zig host process provides the runtime shell (allocators, event loop, filesystem, network, PTY, signals) and embeds QuickJS so existing DSH plugins (transpiled or rewritten as JS) run unmodified.

**Scope:** Zig host + QuickJS embedding layer; DSH plugin code runs as JS inside QuickJS; Zig provides host bindings (fs, net, child_process, timers, console).

**Costs:**
- QuickJS is C — vendoring and building it with Zig is straightforward (zig cc can compile C).
- Must implement QuickJS ↔ Zig host bindings for every Node API DSH uses: fs, net, http, child_process, timers, console, process.env, signals.
- DSH uses ESM (`import`) and Node-specific APIs (`node:fs`, `node:path`, `node:url`, `node:http`). QuickJS does not implement Node's module resolution or built-ins — a shim layer is required.
- `!!js` expressions work natively (they're JS).
- Cordis plugin framework runs as JS code inside QuickJS.

**Risks:**
- QuickJS ES2020 support is incomplete; DSH uses modern TypeScript/Node features (top-level await, `import.meta`, `AbortController`, `fetch`, `structuredClone`, private fields, optional chaining, nullish coalescing). Transpilation to QuickJS-compatible JS is required.
- Node-API addons (landlock-run, flock) cannot run inside QuickJS — need Zig-side replacements exposed as JS bindings.
- Performance: QuickJS is an interpreter; LLM streaming and agent-loop overhead may be acceptable, but not ideal.
- Memory management: QuickJS GC vs Zig manual allocators — boundary must be explicit.
- Event loop mismatch: QuickJS has its own event loop; Zig's must be bridged.

**Leaves out:** Native Node-API addons (replaced by Zig bindings), Node-specific built-ins (shimmed), some modern JS features (transpiled).

---

## Option C: Wire/format-compatible Zig server for a defined subset

Build a Zig server that speaks DSH's wire formats (HTTP API, WebSocket `/api`, SSE streaming, session JSONL format) for a defined subset of functionality. Not a plugin host — a reimplementation of the server surface.

**Scope (subset):**
- CLI: `dsh --profile headless` only (one-shot task runner, no server).
- Session store: JSONL read/write, append/flush, crash recovery.
- LLM: DeepSeek API adapter with SSE streaming, retry, error paths.
- Tools: bash (shell subprocess), fs (read/write/search), todo.
- Agent loop: basic plan → act → observe cycle.
- Config: YAML patch layering (no `!!js`).
- Web server: HTTP API + WebSocket for a minimal client (subset of routes).

**Explicitly out of subset (for now):**
- `web` profile with full browser GUI.
- `sdk` / `acp` profiles.
- Plugin manager / dynamic plugin installation.
- HMR.
- `!!js` config expressions.
- Electron desktop.
- Landlock sandboxing (Phase 2+).
- MCP client.
- Computer-use / browser-use.
- Session title, telemetry, projection-cache.

**Costs:**
- Lowest implementation effort: implement only what's needed.
- Differential testing is straightforward: same CLI input, compare output and session logs.
- Zig std provides allocators, event loop (via `std.posix` or a custom loop), filesystem, networking, PTY, subprocess.
- JSONL + Zstandard: Zstandard C library vendored and compiled with zig cc.
- TLS for DeepSeek API: needs a TLS stack (Zig std has `std.crypto` but not a full TLS client; vendor `zig-socket` or use a C TLS library like mbedtls, or shell out to `openssl`).

**Risks:**
- Subset definition may prove too narrow — users need `web`, `sdk`, plugins.
- Re-implementing the agent loop semantics (turn boundaries, tool history, compaction) is subtle even for a subset.
- Differential testing requires the Node reference to remain runnable for comparison.
- `!!js` expressions dropped — configs using them break.

**Leaves out:** Everything not in the subset (web GUI, plugin system, SDK, ACP, HMR, `!!js`, most specialized tools).

---

## Recommendation

**Option C** — wire/format-compatible Zig server for a defined subset, starting with `headless` profile.

**Rationale:**
- Option A is too large; time to first value is measured in months.
- Option B is technically fragile (QuickJS vs modern Node/ESM surface area, Node-API addons, event loop bridging).
- Option C delivers a testable, differential-verifiable port quickly. The subset grows slice by slice (per the Phase 2+ order).
- The conformance harness (Phase 1) works best against a well-defined wire surface.
- `!!js` expressions are a known risk; dropping them in Phase 0 is an explicit, documented trade-off rather than a surprise later.

**Target profile:** **Web** (user decision, overriding the headless suggestion). The Web profile pulls `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`, which is the broadest surface — model adapters, tools, persistence, sandbox/approval policy, settings, credentials, telemetry, plus the browser application. Starting with Web means the conformance harness exercises the full stack early rather than retrofitting GUI support later.

**Zig version:** 0.17.0, pinned in `build.zig.zon` plus a `.zigversion` file before any port code is written.

**What it leaves out (explicitly):** `sdk`/`acp` profiles, dynamic plugin installation, HMR, `!!js` config expressions, Electron desktop, Landlock sandboxing (Phase 2+), MCP, computer-use, browser-use, session title/telemetry/projection-cache. These are deferred, not rejected; each can be added as a later slice once the core harness is stable.

**Next step:** Phase 0 gate passed. SysLead pins Zig 0.17.0 (`build.zig.zon` + `.zigversion`). Toolsmith starts the conformance harness (Phase 1). Researcher begins spec extraction.
