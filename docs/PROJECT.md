# Arcadia LSP Config for Neovim

## 1. Purpose

`arcadia-lspconfig.nvim` extends Neovim LSP configurations for files that belong
to Arcadia tier0 projects.

The target language set is:

- `clangd` for C and C++
- `pyright` or `basedpyright` for Python
- suppression of `ty` inside Arcadia
- `gopls` for Go
- (probably something else soon)

The implemented built-in workflows are `clangd`, `pyright`, and `basedpyright`,
plus an Arcadia-only suppression policy for `ty`. The two configured Python
servers share one workflow implementation. Other server modules remain planned
work.

Each server is implemented by a separate Lua submodule. A server module owns its
complete Arcadia-specific workflow, including file relevance checks,
asynchronous preparation, incremental configuration changes, and decisions about
when to start or restart an LSP client.

The core provides common infrastructure but does not prescribe one fixed server
lifecycle. For example, `clangd` may apply an initial configuration, restart,
prepare more data, apply a second configuration, and restart again.

## 2. Goals

- Integrate Arcadia-specific configuration with the standard Neovim LSP server
  names and APIs.
- Detect Arcadia projects and their target-specific LSP roots using filesystem
  markers.
- Let server modules implement arbitrary asynchronous, multi-stage preparation
  workflows.
- Share preparation work between buffers that use the same LSP root and server.
- Avoid an unnecessary initial double start when a module needs preparation
  before starting its server.
- Keep independent Arcadia checkouts and `ya.make` roots isolated.
- Make pending work observable through a status API, an animated statusline
  component, health checks, commands, notifications, and optional logs.
- Remain a complete no-op for files outside Arcadia or without an applicable
  `ya.make` root.
- Be testable without a real Arcadia checkout, `ya`, or production LSP server.

## 3. Non-goals

The first version will not:

- Install LSP servers or toolchains.
- Configure formatters or linters.
- Build or test Arcadia targets unrelated to LSP preparation.
- Provide code-generation commands unrelated to LSP preparation.
- Support user-defined or third-party server modules.
- Support repeated calls to `setup()`.
- Support calling `vim.lsp.enable()` before plugin setup.
- Resolve symlinks while detecting roots.

## 4. Requirements and dependencies

- Neovim 0.11.3 or newer is required.
- `nvim-lspconfig` is a required dependency.
- The plugin uses the native `vim.lsp.config()` and `vim.lsp.enable()` APIs.
- External Arcadia tools such as `ya` are not installed by the plugin.
- Missing required tools produce a deduplicated warning rather than a hard
  failure of Neovim.

## 5. User-owned activation

The plugin configures servers during `setup()`, but does not enable them. The
user explicitly chooses which configured servers Neovim should enable:

```lua
vim.lsp.config("clangd", user_clangd_config)

require("arcadia-lspconfig").setup()

vim.lsp.enable("clangd")
```

User LSP configuration must be applied before `setup()`. Enabling a managed
server before `setup()` is unsupported because it may start a client before the
plugin can install its configuration wrapper.

All implemented built-in servers are configured by default. A server can be
excluded:

```lua
require("arcadia-lspconfig").setup({
  servers = {
    clangd = false,
  },
})
```

Excluding a server only prevents this plugin from configuring it. The plugin
does not disable the corresponding ordinary Neovim LSP configuration and does
not call `vim.lsp.enable(false)`.

## 6. Root model

The plugin distinguishes two roots.

### 6.1 Arcadia root

The Arcadia root is the nearest ancestor directory for which `.arc/HEAD`
exists.

If no such directory exists, the plugin performs no Arcadia-specific work.

### 6.2 LSP root

The LSP root is the nearest ancestor directory containing `ya.make`. The search
must not continue above the Arcadia root.

If a file is under an Arcadia root but no applicable `ya.make` is found, the
plugin performs no Arcadia-specific work for that file.

### 6.3 Path handling and caching

- Root detection uses the buffer's visible path and does not resolve symlinks.
- Internal identity uses the full root path rather than a basename or relative
  path.
- Both positive and negative detection results may be cached for the current
  Neovim session.
- Server modules can impose additional file relevance checks.

## 7. Persistent data layout

Generated artifacts are stored below Neovim's data directory:

```text
stdpath("data")/arcadia-lspconfig/<lsp-root-hash>/<server>/
```

`<lsp-root-hash>` is derived from the full LSP root path so that separate roots
and checkouts do not collide. The original Arcadia and LSP root paths remain
available in status information and logs.

Each server module owns the contents of its directory, including cleanup of
partial artifacts left by a failed, timed-out, or cancelled operation.

Persistent artifacts may be reused, but their validity is not trusted across
Neovim sessions. Each session starts background validation or regeneration as
defined by the responsible server module.

## 8. Architecture

### 8.1 Server modules

Built-in server definitions and all server-specific implementation details live
under `lua/arcadia-lspconfig/servers/`. The registry injects an ordered list of
definitions into the server-neutral runtime:

```lua
{
  name = 'example',
  default_options = {},
  allowed_options = {},
  create = function(api)
    return require('arcadia-lspconfig.servers.example')(api)
  end,
}
```

The runtime derives option validation, environment checks, installation,
filetype routing, commands, and health selection from these definitions. It
does not name or inspect a concrete LSP server. A definition's factory receives
the generic core services through dependency injection and returns its
workflow. Server-owned dependencies, such as generated-artifact caches, are
added by the registry before invoking the workflow module.

A module owns:

- Additional file relevance detection.
- External commands and their arguments.
- Preparation stages and their ordering.
- Decisions about whether initial startup must wait for preparation.
- Configuration patches and when they are applied.
- Start and restart decisions.
- Workflow revisions and stale-result checks.
- Refresh behavior.
- Cleanup of partial generated artifacts.
- Server-specific failures and recovery.
- Server-specific health diagnostics.

The `gopls` Arcadia workflow remains intentionally undefined until its module is
implemented. Pyright generates isolated VS Code project data, extracts import paths,
and follows the same cached-start/background-refresh lifecycle as clangd.

### 8.2 Core services

The core exposes an internal API to built-in modules. It provides services for:

- Arcadia and LSP root discovery.
- Full-path-based root/server state.
- Per-root/server data directories.
- Incremental LSP configuration extension.
- Serialized configuration application.
- Async process execution, timeouts, and cancellation.
- Tracking interested, attached, and waiting buffers.
- Detaching clients that use the wrong root.
- Restarting and consolidating LSP clients.
- Status storage and change notification.
- Deduplicated warnings.
- Optional debug logging.
- Dispatching commands and refresh requests.

The internal API is not a public compatibility surface in version 1.

### 8.3 Suggested internal service groups

The concrete names may change during implementation, but the responsibilities
should remain separated along these lines:

```lua
api.root.find(bufnr)
api.paths.data(lsp_root, server)

api.config.extend(lsp_root, server, patch)
api.config.revision(lsp_root, server)

api.jobs.start(lsp_root, server, specification)
api.jobs.cancel(lsp_root, server)

api.clients.detach_wrong_root(server, bufnr, lsp_root)
api.clients.restart(lsp_root, server, buffers)

api.status.set(lsp_root, server, value)
api.notify.warn_once(lsp_root, server, code, message)
api.log.debug(message)
```

Every module invocation receives enough context to distinguish the checkout,
target root, and buffer:

```lua
{
  bufnr = bufnr,
  path = path,
  arcadia_root = arcadia_root,
  lsp_root = lsp_root,
  data_dir = data_dir,
}
```

### 8.4 State isolation and concurrency

Runtime state is keyed by full LSP root and server. The associated Arcadia root
is retained as context.

- Work may run concurrently for different servers under the same root.
- Work may run concurrently for different LSP roots.
- Configuration application is serialized within one LSP root/server pair.
- Several buffers waiting for the same root/server share preparation work.
- When shared preparation completes, all still-interested waiting buffers are
  handled.
- Server modules are responsible for workflow generation numbers and rejecting
  stale asynchronous results.

## 9. Configuration extension

Server modules change LSP configuration through a core wrapper rather than
calling `vim.lsp.config()` directly.

Changes are incremental:

```text
user configuration
  + first Arcadia patch
  + second Arcadia patch
  + later Arcadia patches
```

Merge behavior is:

- Map-like Lua tables are deep-merged.
- List-like Lua tables are replaced.
- Scalar values are replaced.
- No special public replacement marker is provided.

If a later preparation stage fails, the most recent successful configuration
remains active.

Native LSP configurations are registered globally by names such as `clangd`,
while Arcadia extensions vary by full LSP root. The implementation must resolve
and apply a root-specific configuration without allowing one root's patches to
leak into another root. This is a primary architectural risk and should be
validated early with an implementation spike.

## 10. Client lifecycle

There is no hardcoded global lifecycle. A module may wait for preparation before
the first start, start immediately, or reconfigure and restart multiple times.

The core must make it possible for a module to avoid a guaranteed initial double
start when preparation is required before the server can be useful.

### 10.1 Incorrectly rooted clients

If a client attached to an Arcadia buffer does not use the buffer's nearest
`ya.make` directory as its root, the plugin detaches that buffer from the client.

### 10.2 Restart semantics

A restart request is selected through a buffer, but operates on its full LSP
root and server because one LSP client is normally shared by multiple buffers.

The core:

1. Finds every matching client instance for the LSP root/server.
2. Records their attached buffers and any waiting buffers.
3. Stops and consolidates the matching clients.
4. Starts one client with the latest root-specific configuration.
5. Reattaches all still-applicable buffers.

This prevents multiple differently configured instances of the same server from
competing within one LSP root.

### 10.3 Failure during refresh

The current LSP client stays active while replacement preparation runs. If the
new preparation fails, the existing client and last successful configuration
remain active.

Starting a refresh while the same root/server workflow is already running
cancels that workflow and starts it again.

### 10.4 clangd preparation lifecycle

For each applicable root, clangd preparation is a two-stage asynchronous
pipeline:

1. If a valid cached database exists, start checkout-local clangd immediately
   with its directory configured as `compilationDatabasePath`.
2. Concurrently run `ya dump compile-commands` with
   `--cmd-build-root=<data-dir>/build_root` and `ya make --add-result=.hpp
   --add-result=.cpp --replace-result -o=<data-dir>/build_root`.
3. Validate and install successful dump output, then start or restart clangd
   even when the generated database is unchanged.
4. After a successful build, restart clangd only when a valid database is
   already available. Do not replay a skipped restart if make finishes first.

The per-server `codegen` option defaults to `true`. When `false`, omit the
`ya make` stage; compile-command generation alone determines preparation readiness.

No Arcadia or system clangd is started for an applicable buffer without a valid
database. Failure in either stage does not cancel the other stage. Existing
valid clients and databases remain active; a failed initial dump leaves clangd
stopped. A refresh cancels both active stage jobs and begins a new pipeline
revision.

Every asynchronous callback owns its revision-specific temporary artifacts.
A stale callback may clean up only artifacts captured by its own revision; it
must not read or remove paths belonging to current mutable state.

### 10.5 Python preparation lifecycle

Without a project-owned `pyrightconfig.json`, the selected Pyright-compatible
workflow concurrently runs `ya ide vscode --py3 --no-pyright-config` and
`ya make --add-result=.py --replace-result -R` in the LSP root. A valid cached
configuration starts the server before both background stages.

Successful configuration generation validates and installs extra paths, then
restarts the server. A successful build also restarts it when configuration is
already applied. If the build finishes first without configuration, its reload
is skipped rather than deferred. Each stage fails independently; configuration
errors take status priority, and refresh cancels both jobs before starting a new
revision. The per-server `codegen` option defaults to `true`. When `false`, omit
the `ya make` stage; configuration generation alone determines readiness. A
project-owned configuration bypasses both stages.

## 11. Asynchronous jobs

Arcadia preparation commands, including `ya dump compile-commands`,
`ya ide vscode`, and `ya make`, must run asynchronously.

Default job configuration:

```lua
jobs = {
  cancel_on_buff_exit = true,
  timeout_ms = nil,
}
```

`timeout_ms = nil` means there is no default timeout. Users may configure a
timeout, and modules may impose a more specific policy where necessary.

Jobs track the buffers interested in their result:

- Closing a buffer removes its interest.
- A shared job is cancelled only after no interested buffers remain when
  `cancel_on_buff_exit` is enabled.
- Closing one of several interested buffers does not cancel shared work.
- All pending jobs are cancelled when Neovim exits.
- Modules clean up partial artifacts.

## 12. Public Lua API

Version 1 exposes only:

```lua
require("arcadia-lspconfig").setup(options)
require("arcadia-lspconfig").status(bufnr)
require("arcadia-lspconfig").statusline(bufnr)
require("arcadia-lspconfig").refresh(bufnr)
```

`bufnr` is optional and defaults to the current buffer.

### 12.1 Setup options

The initial option shape is:

```lua
require("arcadia-lspconfig").setup({
  servers = {
    clangd = { codegen = true },
    pyright = { codegen = true },
    basedpyright = { codegen = true },
    ty = {},
  },
  jobs = {
    cancel_on_buff_exit = true,
    timeout_ms = nil,
  },
  log = {
    level = "warn",
  },
})
```

Implemented servers are present by default. Setting it to `false` disables
only this plugin's integration for that server. Plugin integration and Neovim
LSP activation are separate: users choose an active Python server with
`vim.lsp.enable()`. Runtime command routing considers enabled servers and
reports an ambiguity if multiple integrations match one buffer.

The ty definition is non-routable: its root callback suppresses ty below an
Arcadia root and delegates to the original nvim-lspconfig root logic elsewhere.
It never participates in refresh or restart workflow selection.

## 13. Status and events

Status is tracked by full LSP root and server, then projected onto buffers.

An illustrative structured result is:

```lua
{
  arcadia_root = "/path/to/arcadia",
  lsp_root = "/path/to/arcadia/project",
  servers = {
    clangd = {
      state = "waiting",
      stage = "compile_commands",
      message = "Generating compile commands",
      revision = 2,
    },
  },
}
```

At minimum, server status supports states such as:

- `idle`
- `waiting`
- `ready`
- `warning`
- `error`

Modules may supply meaningful `stage` and `message` values.

The clangd workflow uses `stage = "prepare"` while both jobs run and after both
succeed. When only one job remains, or after a failure, it uses
`stage = "compile_commands"` or `stage = "build"`. Dump errors take priority
when both stages fail.

The Python workflows use the same aggregation with their server-specific
configuration stage and `stage = "build"`. Configuration errors take priority
over build errors.

### 13.1 Statusline

`statusline(bufnr)` returns one generic animated wait indicator while any server
applicable to the buffer is waiting:

```text
lsp ⠋
lsp ⠙
lsp ⠹
```

The animation frame is derived from elapsed time. Multiple waiting servers still
produce only one `lsp X` indicator. The function returns an empty string when no
applicable server is waiting, including when work is ready or the buffer is
outside Arcadia.

### 13.2 Status change event

The plugin emits the following event when relevant status changes:

```text
User ArcadiaLspStatusChanged
```

The event data is intentionally unspecified and is not a public API. Consumers
use the event only as a redraw signal, then call `status()` or `statusline()`.

## 14. Commands

The plugin provides:

- `:LspArcadiaRefresh` to cancel and restart the workflow selected by the current
  buffer's LSP root and applicable server.
- `:LspArcadiaStatus` to show the current buffer's Arcadia LSP status.
- `:LspArcadiaRestart` to restart the current buffer's root/server client using
  the latest successful configuration.

The commands operate on the current buffer. There are no bang or all-roots
variants in version 1.

## 15. Notifications and logging

Normal detection and successful preparation are silent.

Missing tools and other actionable preparation failures produce warnings. A
warning is emitted once per Neovim session for each combination of:

```text
full LSP root + server + stable error code
```

Modules use the core notification wrapper so warning deduplication is
consistent.

Debug logging is opt-in. Logs are stored under:

```text
stdpath("state")/arcadia-lspconfig.log
```

Logs should contain root, server, stage, job, configuration revision, client,
and error context sufficient to diagnose asynchronous workflow behavior.

## 16. Health checks

`:checkhealth arcadia-lspconfig` reports:

- Whether the Neovim version is supported.
- Whether `nvim-lspconfig` is available.
- Arcadia root detection for the current buffer.
- Nearest bounded `ya.make` root detection.
- Availability and executability of `ya` when required.
- Availability of configured LSP executables.
- Root/server data paths and relevant generated artifacts.
- Currently running async jobs.
- The last recorded warning or error for each applicable root/server.

The health check should remain useful when no Arcadia buffer is currently open;
in that case project-specific checks are reported as unavailable rather than as
plugin failures.

## 17. Testing strategy

The project requires both unit and integration tests.

### 17.1 Unit tests

Unit tests cover at least:

- Arcadia root detection through `.arc/HEAD`.
- Nearest `ya.make` detection bounded by the Arcadia root.
- Behavior outside Arcadia and without `ya.make`.
- Positive and negative root caching.
- Full-path hashing and data-directory isolation.
- Deep merging of maps and replacement of lists.
- Incremental configuration layers.
- Serialization by LSP root/server.
- Job interest tracking and `cancel_on_buff_exit` behavior.
- Warning deduplication.
- Structured status projection.
- Animated and empty statusline rendering.

### 17.2 Integration tests

Integration tests use:

- Temporary directory trees containing fake `.arc/HEAD` and `ya.make` markers.
- Fake asynchronous preparation executables.
- Fake LSP executables.
- Multiple buffers sharing one root/server.
- Multiple roots and servers running concurrently.

They verify at least:

- Explicit `vim.lsp.enable()` activation.
- Avoidance of an unnecessary initial double start.
- Shared preparation across buffers.
- Multi-stage configuration and repeated restart flows.
- Detachment from incorrectly rooted clients.
- Consolidation and reattachment during restart.
- Refresh cancellation and restart.
- Preservation of the existing client after preparation failure.
- Cancellation when the last interested buffer exits.
- Isolation between full LSP roots.

Tests must not require a real Arcadia checkout, a real `ya` installation, or
production language servers.

## 18. Known limitations and implementation risks

- Root-specific settings must coexist with Neovim's globally named LSP
  configurations. The configuration wrapper must prevent cross-root state
  leakage.
- Module-owned control flow provides flexibility but makes stale async completion
  handling a module responsibility.
- A root/server restart necessarily affects every buffer sharing that client,
  even though a command is selected through one current buffer.
- Symlinked views of the same checkout may be treated as distinct roots because
  paths are not resolved.
- Session-start background invalidation may temporarily use existing artifacts;
  each module decides when those artifacts are sufficiently valid to start or
  restart its server.
- Go and future server-specific Arcadia commands, settings, and relevance rules
  remain to be specified in their respective modules.

## 19. Initial implementation priorities

1. Validate root-specific resolved configuration with globally named native LSP
   configs.
2. Implement and test root discovery and state isolation.
3. Implement configuration layering and root/server serialization.
4. Implement the shared async job service and cancellation semantics.
5. Implement buffer/client tracking, detach, restart, consolidation, and
   reattachment.
6. Implement status, statusline, events, notifications, logging, commands, and
   health checks.
7. Add future server module shells.
8. Define and implement each server-specific Arcadia workflow independently.
