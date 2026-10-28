# DSH to Zig Port — Architecture Inventory (Phase 0)

Source of truth: `deepseek-harness` at tag `dsh-v0.2.0-rc.2` (commit `639ed01539`), checked out at `/workspace/dsh-zig/original`. Do not track upstream HEAD.

This document inventories the existing Node/TypeScript DSH so the Zig port can be planned against real surfaces, not assumptions. It is produced from the source.

---

## 1. Package graph

The monorepo has **61 packages** under `packages/` plus 4 apps under `apps/` and 6 vendored packages under `vendor/`.

**Apps:**
- `apps/cli` — the `dsh` CLI launcher (profile boot, config dumps, plugin management). ~992 LOC TS.
- `apps/web` — web frontend shell (build output only in source tree).
- `apps/desktop` — Electron desktop application (~7808 LOC TS).
- `apps/desktop-host` — desktop host (~401 LOC TS).

**Core package groups (61 total):**

| Group | Packages | Role |
|---|---|---|
| boot | app-boot, cmdline, config-editor, hmr, plugin-manager | Profile boot, patch layering, plugin management, HMR |
| llm | llm, llm-deepseek, llm-deepseek-account, llm-deepseek-api-key, llm-pi-ai, llm-retry, token-meter | LLM message types, streaming, adapters, DeepSeek provider |
| session | session, session-persistence, session-persistence-jsonl, session-projection, session-query, session-reference, session-title, session-telemetry, + format migration packages | Session event log, persistence, projection, title, telemetry |
| core | agent, agent-loop, agent-tool-presentation, scope, system-prompt, tools | Agent loop, tool execution, system prompt, scope |
| host | webserver, frontend-static, directory-picker-*, open-in-app, plugin-inventory, product-telemetry-otel | HTTP server, static asset serving, frontend plugins |
| mcp | mcp | MCP client protocol |
| sandbox | sandbox | Sandbox policy |
| shell | shell | Shell tool |
| terminal | terminal | Terminal/PTY tool |
| subprocess | subprocess | Subprocess execution |
| fs | fs | Filesystem tool |
| skill | skill | Skill system |
| workflow | workflow | Workflow engine |
| plan | plan | Plan mode |
| goal | goal | Goal management |
| todo | todo | Todo tool |
| jobs | jobs | Job management |
| schedule | schedule | Scheduling |
| storage | storage | Storage abstractions |
| credentials | credentials | Credential store |
| settings | settings | Settings service |
| identity | identity | Identity |
| interaction | interaction | Interaction model |
| hooks | hooks | Hook system |
| guard | guard | Guardrails |
| feedback | feedback | Feedback |
| attachment | attachment | Attachments |
| deliverables | deliverables | Deliverables |
| document | document | Document processing |
| spill | spill | Spill |
| webhook | webhook | Webhooks |
| experimental | experimental | Experimental features |
| browser-use | browser-use | Browser automation |
| computer-use | computer-use | Computer use |
| lsp | lsp | Language server |
| acp | acp | Agent Communication Protocol |
| api | api | API surface |
| bundle | bundle | Bundle packaging |
| client | client | Client UI |
| context | context | Context management |
| sdk | sdk | SDK |
| typert | typert | Type system |
| test-support | test-support | Test utilities |
| util | util | Utilities |
| workspace | workspace | Workspace |
| runtime-diagnostics | runtime-diagnostics | Diagnostics |
| ptc-runtime | ptc-runtime | PTC runtime |

**Total TS source files: ~3,693 in packages/, ~522 in apps/.** No per-package LOC was obtainable (build tooling interferes), but the tree is large: roughly 300k+ LOC of TypeScript across all packages.

**Vendored (under `vendor/`):** cordis, cosmokit, group, hmr, include, logger-console, schemastery, timer. Cordis is the framework — plugins mount services, events, and reversible effects into a shared context.

**Native (under `native/system/`):** prebuilt Node-API addons per platform (darwin-arm64, darwin-x64, linux-arm64, linux-x64). Package `@deepseek-ai/node-addon-system` provides:
- `landlock-run` — C11 Landlock sandbox launcher (no libraries beyond libc, musl linked statically)
- `flock` — Node-API v8 binding for asynchronous `flock(LOCK_EX | LOCK_NB)`

Source: `native/system/packages/entry/src/main.c` and `flock.c`.

---

## 2. External surfaces

### CLI flags (launcher, `apps/cli/src/args.ts`)

The launcher parses only its own flags; everything after the first unrecognized token is handed verbatim to the booted profile.

| Flag | Meaning |
|---|---|
| `<name>` (positional) | Abbreviates `--profile <name>` |
| `--profile <name>` | Profile under `$DSH_HOME/profiles` to boot (required unless `-h`) |
| `--from-default-profile <name>` | Initialize a new custom profile from a shipped template |
| `--patch <path>` | Extra patch-list overlay, repeatable, applied in argv order |
| `--dump-config` | Print composed profile tree and exit (no boot) |
| `--dump-config-schema` | Print JSON Schema for profile entries/patches without mounting |
| `--dump-default-config` | Print tree without user layer or `--patch` overlays |
| `--version` / `-V` | Print version |
| `plugin --profile <name> <pnpm-args...>` | Forward pnpm args to profile directory |

Sub-profiles (apps) print their own `--help` through injected app plugins.

### Shipped profiles (templates in `packages/boot/app-boot/src/profile.ts`)

| Profile | Bundles |
|---|---|
| `web` | `@deepseek-ai/dsh-base`, `@deepseek-ai/dsh-web-app` |
| `headless` | `@deepseek-ai/dsh-base`, `@deepseek-ai/dsh-headless` |
| `sdk` | `@deepseek-ai/dsh-base`, `@deepseek-ai/dsh-sdk-app` |
| `sdk-minimal` | `@deepseek-ai/dsh-sdk-minimal` (standalone, no `dsh-base`) |
| `acp` | `@deepseek-ai/dsh-base`, `@deepseek-ai/dsh-acp-app` |

### HTTP / WebSocket API

**`dsh-host-webserver`** (`packages/host/webserver`): single `node:http` plugin providing `ctx.webServer`.

- Named-route registry: `exact` or `prefix` match; exact table first, then longest prefix, then fallback.
- One fallback seat; a plugin claims it (Web composition claims with `dsh-host-frontend-static`).
- Optional gzip response compression (level 0-9, threshold bytes).
- `Connection` plugin supplies Host/Origin checks + browser-session auth for `/api` routes and streams.
- SSE supported (handlers hold responses open).
- Config: `host` (`127.0.0.1` \| `0.0.0.0`), `port` (0 = OS-assigned), `compression`, `compressionLevel`, `compressionThresholdBytes`.
- No TLS, no auth in the carrier itself — composition supplies those.

**WebSocket:** via the `Connection` plugin (shared-channel RPC interceptor), `createSharedFetchHandler('/api')`. Electron uses `file://` + IPC bridge instead of this server.

### Config schema

YAML-based config rows with `!!js` embedded JavaScript expressions. Schema is generated by `scripts/gen-config-catalog.ts` and verified by `verify-config-catalog`. The schema covers profile entries, bundle patches, and all plugin config fields. `dump-config-schema` prints it without mounting.

### On-disk formats

| Format | Location | Notes |
|---|---|---|
| Profile | `$DSH_HOME/profiles/<name>/` | `package.json` (out-of-tree deps + `dsh.profile` manifest with ordered `bundles`), `cordis.patch.yml` (user patch layer), `cordis.yml` (empty root entry list) |
| Session event log | JSONL per session, checksummed concatenated Zstandard frames (default) or raw lines | `packages/session/session-persistence-jsonl` |
| Session header | Separate from log | version, id, createdAt, cwd, parentSession, isSeeded, origin, delegationDepth, agentPreset |
| Bundle patch | `dsh.bundle.patch` in package.json | One file or ordered list of YAML patch files |
| SQLite schema | Not present | No SQLite in this release; persistence is JSONL-only |

No SQLite schema exists in v0.2.0-rc.2. Session persistence is JSONL + Zstandard.

### Environment variables

| Var | Purpose |
|---|---|
| `DSH_HOME` | Harness home (bootstrap-only; profiles live under `$DSH_HOME/profiles`) |
| `DSH_TELEMETRY_DISABLED` | Telemetry off switch |
| `DSH_SNAPSHOT` | Snapshot mode; `replay` swaps `cordis.yml` for `cordis.snapshot.yml` |
| `NODE_USE_ENV_PROXY` | Node proxy env (not sufficient; DSH resolves proxy from launch snapshot) |

---

## 3. Config / patch layering model

Patch layers apply to an empty entry list in this order:

1. **Bundle layers** — each bundle in `dsh.profile.bundles` order; a base-backed profile gets the base bundle's platform-gated shell rows.
2. **Profile's own layer** — `cordis.patch.yml` in the profile directory.
3. **Home-level user layer** — `$DSH_HOME/cordis.patch.yml` (machine-local preferences; outranks per-profile).
4. **`--patch` overlays** — in argv order.
5. **Telemetry switch** — applied last.

A patch targets a row by id and replaces its whole config, or inserts new rows. The Loader's tree write-back can bake composed rows into `cordis.yml`, so the root config is always rewritten as an empty entry list on boot to avoid duplicating bundle inserts.

**Embedded JS expressions:** `!!js` expressions are supported in config values (via Cordis Loader). `dshHomePath` is exposed to `!!js` expressions as a context-provided resolver. Config dumps do **not** evaluate `!!js` (boot-free).

---

## 4. Plugin model

**Everything-is-a-plugin** architecture on Cordis:

- Plugins contribute services, typed events, and reversible effects to a shared `Context`.
- No privileged core to patch — extend by mounting a plugin beside others.
- Registrations are effects that unwind when the plugin unloads.
- `ctx.plugin(Plugin)` mounts a plugin; `ctx.get(service)` / `ctx.provide(key, value)` for service lookup.
- Fiber model: `FiberState` (ACTIVE, etc.); `ctx.fiber.dispose()` for teardown.
- Events: `ctx.on(event, handler)` / `ctx.emit(event, payload)`; dispatch modes include `emit`.
- HMR: config-only or module hot-reload; `ctx.hmr.watchConfig`, `runExclusive`, `getLinked`.
- Plugin Manager: install/remove/enable/disable bundles via pnpm; version exemptions; registry probing.

**What ds-bot needs from the host:** The CLI launcher (`bin.ts`) provides:
- Environment snapshot (`loadLayeredEnv('dsh')`) before any plugin mounts.
- Proxy resolution from the launch snapshot (Node's `fetch` ignores `process.env` proxy at start).
- `DSH_HOME` resolution.
- Signal handling (SIGTERM → exit 0, SIGINT → exit 130).
- Fail-loud error handling with bounded shutdown.
- `ProfileContext`: name, dir, patchPath, installAnchor, startedBundles, cwd, home, overlays, telemetryDisabledEnv.
- `cmdlineArgs`: invocation's inner arguments, frozen for the run.
- `AppReady` readiness signal committed after boot + host setup.

---

## 5. Key external dependencies (runtime)

- Node.js `^22.19.0 || >=24.0.0`
- `commander` (CLI parsing), `js-yaml` (YAML), `ws` (WebSocket), `ajv` (validation)
- Cordis framework (vendored)
- pnpm (workspace package manager, v11.7.0)
- Native Node-API addons (landlock-run, flock) — prebuilt per platform

---

## 6. Risk items for the port

- `!!js` embedded JavaScript expressions in config — requires a JS engine or removal.
- PTY / terminal handling (`packages/terminal`, `packages/shell`).
- Landlock sandboxing (Linux-only C addon).
- WebSocket + SSE streaming.
- Node-API addon ABI (flock, landlock-run).
- SQLite is **not** used (JSONL only) — one less porting concern.
- The `dsh-base` bundle is the shared first layer for most profiles — it pulls in many subsystems.
