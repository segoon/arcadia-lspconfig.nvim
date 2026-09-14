## Core documentation

- @docs/PROJECT.md - the core concept, the project goals, user scenarios
- @README.md - the main user documentation
- doc/arcadia-lspconfig.nvim.txt - the vim help file

## Quick Reference

**Language:** Lua. Neovim plugin. Minimum Neovim: 0.11.

**Conventions**
- stylua
- luacheck
- luacats annotations (**MANDATORY**)
- make test + make format + make lint

## Development

- TDD
- DRY, KISS, SOLID
- When fixing a bug, search for similar bugs in the nearby code
- When found a bug, elaborate whether it is possible to redesign the system to make such bugs impossible
- max *.lua file size = 600 lines

## Documentation

- `doc/arcadia-lspconfig.nvim.txt` — the vim help file (`:help arcadia-lspconfig.nvim`),
  hand-written (no generator in this repo)
- Any change that adds or changes commands, config options, or public API **must** update it and
  `README.md`

## User interaction

User experience is the priority.
Handle anything related to user interaction very carefully.
Examples:
- error messages (`vim.notify`, `:checkhealth`)
- documentation
- `setup()` and its validation
- user commands
