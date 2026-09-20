# arcadia-lspconfig.nvim

Arcadia-aware extensions for Neovim's native LSP configuration.
You don't have to additionally configure LSP servers for Arcadia, it should "just work" out of the box after LSP server is installed.

The plugin supports:
- C and C++ through `clangd`
- Python through `pyright` or `basedpyright` (and disables `ty`)
- Protocol Buffers through `protols`
- `ya.make` files through the automatically managed `ya-make-lsp`

# Requirements

- Neovim 0.11.3 or newer
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- An Arcadia checkout with executable `ya` and `arc` commands
- Node.js and npm for building `ya-make-lsp`

The plugin does not install Arcadia tools or general-purpose language servers.
It does automatically export, build, and update `ya-make-lsp` from Arcadia
trunk.

# How to start

1. Install this plugin, e.g. via lazy.nvim:
```lua
{
  'segoon/arcadia-lspconfig.nvim',
  dependencies = {
    'neovim/nvim-lspconfig',
  },
  opts = {}
}
```
2. Install LSP servers, e.g. via [mason](https://github.com/mason-org/mason.nvim)
3. Call `vim.lsp.enable(...)` for LSP servers:

```lua
vim.lsp.enable('clangd')
vim.lsp.enable('basedpyright')
vim.lsp.enable('protols')
```

`ya-make-lsp` is enabled automatically. Opening an Arcadia `ya.make` file
installs and starts it; no separate `vim.lsp.enable()` call is needed.

# LSP settings

## C++

clangd starts the following commands in background:

1. `<arcadia-root>/ya dump compile-commands`
2. `<arcadia-root>/ya make --add-result=.hpp --add-result=.cpp --replace-result`

Set `servers.clangd.codegen = false` to skip the `ya make` codegen stage.

After that, LSP server is restarted.

Both `compile_commands.json` and codegen results are stored in `~/.local/share/nvim/arcadia-lspconfig/<hash>/clangd/`.

## Python

pyright / basedpyright start the following commands in background:

1. `<arcadia-root>/ya ide vscode --py3`
2. `<arcadia-root>/ya make --add-result=.py --replace-result`

Set `codegen = false` for the selected Python server to skip the `ya make` codegen stage.

After that, LSP server is restarted.

vscode project and codegen results are stored in `~/.local/share/nvim/arcadia-lspconfig/<hash>/pyright/`.

## Protocol Buffers

For an Arcadia Proto target, Protols runs this command in the nearest `ya.make`
directory:

```text
<arcadia-root>/ya dump build-plan . --ignore-recurses
```

The complete build plan is cached. Effective source import roots are extracted
from its `protoc` commands and passed as `init_options.include_paths`. All
source `.proto` inputs in the plan share that cache, including dependencies in
other `ya.make` modules. Generated imports under `$(BUILD_ROOT)` are not
configured.

Protols invokes Arcadia tools through cache-local wrappers. Formatting runs
`<arcadia-root>/ya tool clang-format`; diagnostics run
`<arcadia-root>/ya run <arcadia-root>/contrib/tools/protoc -- ...`. The wrappers
preserve Protols' working directory. A project `protols.toml` remains untouched;
explicit tool paths there take precedence over these wrappers.

The raw build plans and derived index are stored under the checkout-specific
`stdpath("data")/arcadia-lspconfig/<hash>/protols/` directory.

## ya.make

Opening a file named exactly `ya.make` sets the `yamake` filetype and enables
`ya-make-lsp`. On first use the plugin runs:

```text
arc log -n1 trunk --oneline devtools/ide/vscode-yandex-arc/ya-make-lsp
arc export trunk devtools/ide/vscode-yandex-arc/ya-make-lsp --to <data-dir>
npm install
npm run build
```

The npm commands run in the exported directory, never in the Arcadia checkout.
The installation is stored at
`stdpath("data")/arcadia-lspconfig/ya-make-lsp/`. Later opens start the cached
server immediately, check the trunk revision in the background, and rebuild and
restart only after the revision changes. Failed updates restore the last working
installation.

# Advanced configuration

Defaults:

```lua
require('arcadia-lspconfig').setup({
  servers = {
    -- set a server to `false` to leave it unmanaged by this plugin
    -- set codegen to false to skip ya make --replace-result
    clangd = { codegen = true },
    pyright = { codegen = true },
    basedpyright = { codegen = true },
    -- use `ty = false` to avoid disabling ty (it doesn't work well with arcadia python)
    ty = {},
    protols = {},
    -- automatically installed and enabled for exact ya.make files
    ['ya-make-lsp'] = {},
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

- `:LspArcadiaRefresh` reruns preparation for the current buffer's applicable
  server.
- `:LspArcadiaStatus` displays structured status.
- `:LspArcadiaRestart` restarts the current root's applicable clangd, Pyright,
  BasedPyright, Protols, or ya-make-lsp client when its required configuration
  is available.
- `:checkhealth arcadia-lspconfig` checks dependencies, roots, Arcadia `ya`,
  server-specific cache state, and the current workflow for the file from which
  it was invoked.
