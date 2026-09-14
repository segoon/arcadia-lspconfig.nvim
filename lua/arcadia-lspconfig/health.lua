local M = {}

local health = vim.health

local function version_ok()
  local version = vim.version()
  return version.major > 0 or version.minor > 11 or (version.minor == 11 and version.patch >= 3)
end

function M.check()
  health.start 'arcadia-lspconfig.nvim'

  if version_ok() then
    local version = vim.version()
    health.ok(('Neovim %d.%d.%d is supported'):format(version.major, version.minor, version.patch))
  else
    health.error 'Neovim 0.11.3 or newer is required'
  end

  if #vim.api.nvim_get_runtime_file('lsp/clangd.lua', false) > 0 then
    health.ok 'nvim-lspconfig provides lsp/clangd.lua'
  else
    health.error 'nvim-lspconfig is not available on runtimepath'
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    health.info 'The current buffer has no file path; project checks were skipped'
    return
  end

  local roots = require('arcadia-lspconfig.root').find(name)
  if not roots.arcadia_root then
    health.info 'The current buffer is outside Arcadia'
    return
  end
  health.ok(('Arcadia root: %s'):format(roots.arcadia_root))

  if not roots.lsp_root then
    health.warn 'No ya.make was found between the current file and the Arcadia root'
    return
  end
  health.ok(('LSP root: %s'):format(roots.lsp_root))

  local ya_path = vim.fs.joinpath(roots.arcadia_root, 'ya')
  if vim.fn.executable(ya_path) == 1 then
    health.ok(('Arcadia ya is executable: %s'):format(ya_path))
  else
    health.error(('Arcadia ya is not executable: %s'):format(ya_path))
  end

  local data_dir = require('arcadia-lspconfig.paths').data(roots.lsp_root, 'clangd')
  health.info(('clangd data directory: %s'):format(data_dir))
  local database = vim.fs.joinpath(data_dir, 'compile_commands.json')
  if require('arcadia-lspconfig.cache').is_valid(database) then
    health.ok(('Valid compilation database: %s'):format(database))
  elseif vim.uv.fs_stat(database) then
    health.error(('Invalid compilation database: %s'):format(database))
  else
    health.info 'No cached compilation database exists yet'
  end

  local state = require('arcadia-lspconfig')._state()
  local workflow = state.workflows.clangd
  if not workflow then
    health.info 'Arcadia clangd integration is not configured'
    return
  end
  local server_state = workflow._states()[roots.lsp_root]
  if not server_state then
    health.info 'No clangd workflow has run for this root in the current session'
  elseif server_state.running then
    health.info(('clangd preparation revision %d is running'):format(server_state.revision))
  else
    health.info(('clangd preparation revision: %d'):format(server_state.revision))
  end
end

return M
