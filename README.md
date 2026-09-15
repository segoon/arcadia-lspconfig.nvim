# arcadia-lspconfig.nvim

Arcadia-aware extensions for Neovim's native LSP configuration.
You don't have to additionally configure LSP servers for Arcadia, it should "just work" out of the box after LSP server is installed.


The plugin supports:
- C and C++ through `clangd`
- Python through `pyright` or `basedpyright` (and disables `ty`)


# Requirements

- Neovim 0.11.3 or newer
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- An Arcadia checkout with an executable `<arcadia-root>/ya`

The plugin does not install language servers or Arcadia tools.

# How to start

1. Setup this plugin
2. Install LSP servers (e.g. via [mason-lspconfig](https://github.com/mason-org/mason-lspconfig.nvim))
3. Call `vim.lsp.config(...)`, if you want
3. `vim.lsp.enable(...)` for LSP servers (`clangd`, `basedpyright`)

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
vim.lsp.enable('basedpyright')
```

# LSP settings

## C++

clangd starts the following commands in background:

1. `<arcadia-root>/ya dump compile-commands`
2. `<arcadia-root>/ya make --add-result=.hpp --add-result=.cpp --replace-result`

After that, LSP server is restarted.

## Python

pyright / basedpyright start the following commands in background:

1. `<arcadia-root>/ya ide vscode --py3`
2. `<arcadia-root>/ya make --add-result=.py --replace-result`

After that, LSP server is restarted.

# Advanced configuration

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
~/.local/state/nvim/arcadia-lspconfig.log
```

## API

```lua
local arcadia_lsp = require 'arcadia-lspconfig'

-- `bufnr` is optional and defaults to the current buffer.
arcadia_lsp.status(bufnr)
arcadia_lsp.statusline(bufnr)
arcadia_lsp.refresh(bufnr)
```

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

- `:LspArcadiaRefresh` reruns preparation for the current buffer.s applicable
  server.
- `:LspArcadiaStatus` displays structured status.
- `:LspArcadiaRestart` restarts the current root's applicable clangd, Pyright,
  or BasedPyright client when its required configuration is available.
- `:checkhealth arcadia-lspconfig` checks dependencies, roots, Arcadia `ya`,
  server-specific cache state, and the current workflow for the file from which
  it was invoked.
