# arcadia-lspconfig.nvim

Arcadia-aware extensions for Neovim's native LSP configuration.

The plugin supports:
- C and C++ through `clangd`
- Python through `pyright` or `basedpyright` (and disables `ty`)


## clangd

For every applicable Arcadia `ya.make` root, clangd starts the following commands in background:

1. `<arcadia-root>/ya dump compile-commands`
2. `<arcadia-root>/ya make --add-result=.hpp --add-result=.cpp --replace-result`
3. reloads clangd after a successful result

Outside Arcadia, or when no `ya.make` exists, the plugin leaves the normal
`nvim-lspconfig` LSP server behavior unchanged.

Otherwise it runs `ya ide vscode --py3`, caches generated import paths outside
Arcadia, and starts or reloads Pyright after successful preparation.

## Requirements

- Neovim 0.11.3 or newer
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- An Arcadia checkout with an executable `<arcadia-root>/ya`

The plugin does not install language servers or Arcadia tools.

## Installation

Minimal config, with lazy.nvim:

```lua
{
  'segoon/arcadia-lspconfig.nvim',
  dependencies = {
    'neovim/nvim-lspconfig',
  },
  opts = {}
}
```

Apply ordinary clangd and Pyright customizations before setup. The user remains
responsible for enabling each server:

```lua
vim.lsp.config('clangd', {
  capabilities = my_capabilities,
})

vim.lsp.enable('clangd')
vim.lsp.enable('pyright')
```

## Configuration

Defaults:

```lua
require('arcadia-lspconfig').setup({
  servers = {
    -- set a server to `false` to leave it unmanaged by this plugin
    clangd = {},
    pyright = {},
    basedpyright = {},
    -- use `ty = false` to avoid disabling ty (it doesn't work well with arcadia python)
    ty = {},
  },
  jobs = {
    cancel_on_buff_exit = true,
    -- set to non-nil to define a hard timeout
    timeout_ms = nil,
  },
  log = {
    -- supported log levels are `debug`, `info`, `warn`, `error`, and `off`
    level = 'warn',
  },
})
```

Debug logs are written to:

```text
stdpath('state')/arcadia-lspconfig.log
```

## Detection and cache

The Arcadia root is the nearest ancestor containing `.arc/HEAD`. The LSP root
is the nearest ancestor containing `ya.make`, and its search stops at the
Arcadia root. Symlinks are not resolved.

Each full LSP root gets isolated caches:

```text
stdpath('data')/arcadia-lspconfig/<sha256-of-lsp-root>/clangd/compile_commands.json
```

The selected Python server stores a validated manifest and generated `.links`
tree below its server-specific cache directory. Existing
`{lsp-root}/pyrightconfig.json` files take precedence and bypass preparation.
Without one, cached paths start the server immediately while two commands run
concurrently in the background:

```text
cwd: <lsp-root>
<arcadia-root>/ya ide vscode --py3 --no-pyright-config \
  -W=arcadia-pyright -P=<revision-project-directory>

cwd: <lsp-root>
<arcadia-root>/ya make --add-result=.py --replace-result -R
```

Without a valid cache, the server waits for successful extra-path generation.
A successful generation starts or reloads the server. A successful Python build
reloads it only when configuration is already available; if the build finishes
first, that reload is skipped rather than replayed later. Failure in either
stage does not cancel the other, and existing working configuration and clients
are preserved.

The preparation commands run concurrently:

```text
cwd: <lsp-root>
<arcadia-root>/ya dump compile-commands \
  --output-file=<temporary-file> \
  --cmd-build-root=<data-dir>/build_root

cwd: <lsp-root>
<arcadia-root>/ya make \
  --add-result=.hpp \
  --add-result=.cpp \
  --replace-result \
  -o=<data-dir>/build_root
```

Output must be a JSON array. It replaces the previous database atomically only
after successful validation. A successful dump starts or reloads clangd. A
successful `ya make` reloads clangd only when a valid database is already
available.

On the first open in a session:

- With a valid cache, clangd starts immediately before background preparation.
  Each successful parallel stage reloads it.
- Without a valid cache, no clangd client starts until the dump installs one.
  If make finishes first, its reload is skipped rather than replayed later.
- If generation fails without a valid cache, no checkout-local or system clangd
  is started for the Arcadia buffer.
- Failure in either preparation stage does not cancel the other. Existing valid
  clients and databases remain active.
- If Arcadia `ya` is missing or not executable, the plugin warns once and
  cannot start Arcadia clangd.

## API

```lua
local arcadia_lsp = require 'arcadia-lspconfig'

arcadia_lsp.status(bufnr)
arcadia_lsp.statusline(bufnr)
arcadia_lsp.refresh(bufnr)
```

`bufnr` is optional and defaults to the current buffer.

`status()` returns `nil` outside an applicable Arcadia root. Otherwise it
returns:

```lua
{
  arcadia_root = '/path/to/arcadia',
  lsp_root = '/path/to/arcadia/project',
  servers = {
    clangd = {
      state = 'waiting',
      stage = 'compile_commands',
      message = 'Generating compile commands',
      revision = 1,
    },
  },
}
```

While both jobs run, the server reports `state = 'waiting'` and
`stage = 'prepare'`. Once only one remains, its specific stage is reported.
After both finish, configuration-generation errors take priority over build
errors. The same aggregation applies to the parallel Python preparation stages.

`statusline()` returns one animated `lsp X` indicator while preparation is
pending, and an empty string otherwise:

```lua
require('lualine').setup({
  sections = {
    lualine_x = {
      function()
        return require('arcadia-lspconfig').statusline()
      end,
    },
  },
})
```

The animation frame is derived from elapsed time. Configure the statusline
plugin's refresh interval if continuous animation is desired.

`refresh()` returns `true` after dispatching work. It returns `nil, message`
when the buffer is not refreshable.

The internal `User ArcadiaLspStatusChanged` event is emitted as a redraw signal.
Its event data is deliberately unspecified; consumers should call `status()` or
`statusline()`.

## Commands

- `:LspRefreshArcadia` reruns preparation for the current buffer.s applicable
  server.
- `:ArcadiaLspStatus` displays structured status.
- `:ArcadiaLspRestart` restarts the current root's applicable clangd, Pyright,
  or BasedPyright client when its required configuration is available.
- `:checkhealth arcadia-lspconfig` checks dependencies, roots, Arcadia `ya`,
  server-specific cache state, and the current workflow for the file from which
  it was invoked.
