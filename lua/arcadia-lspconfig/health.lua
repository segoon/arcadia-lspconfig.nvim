local M = {}

local health = vim.health

local function version_ok()
  local version = vim.version()
  return version.major > 0 or version.minor > 11 or (version.minor == 11 and version.patch >= 3)
end

---@return integer
local function project_buffer()
  local current = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(current)
  if not vim.startswith(name, 'health://') then
    return current
  end

  local alternate = vim.fn.bufnr '#'
  if alternate > 0 and vim.api.nvim_buf_is_valid(alternate) then
    return alternate
  end
  return current
end

---@param roots table
local function check_pyright(roots)
  local data_dir = require('arcadia-lspconfig.paths').data(roots.lsp_root, 'pyright')
  health.info(('pyright data directory: %s'):format(data_dir))
  local project_config = vim.fs.joinpath(roots.lsp_root, 'pyrightconfig.json')
  if vim.uv.fs_stat(project_config) then
    health.ok(('Project Pyright configuration: %s'):format(project_config))
  else
    local manifest = vim.fs.joinpath(data_dir, 'config.json')
    local cached, cache_error = require('arcadia-lspconfig.pyright_cache').read(manifest)
    if cached then
      health.ok(('Valid cached Pyright configuration: %s'):format(manifest))
    elseif vim.uv.fs_stat(manifest) then
      health.error(('Invalid cached Pyright configuration: %s'):format(cache_error))
    else
      health.info 'No cached Pyright configuration exists yet'
    end
  end

  local workflow = require('arcadia-lspconfig')._state().workflows.pyright
  local server_state = workflow and workflow._states()[roots.lsp_root] or nil
  if not workflow then
    health.info 'Arcadia Pyright integration is not configured'
  elseif not server_state then
    health.info 'No Pyright workflow has run for this root in the current session'
  else
    health.info(
      ('Pyright preparation revision %d%s'):format(
        server_state.revision,
        server_state.running and ' is running' or ''
      )
    )
  end
end

---@param roots table
local function check_clangd(roots)
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

  local workflow = require('arcadia-lspconfig')._state().workflows.clangd
  if not workflow then
    health.info 'Arcadia clangd integration is not configured'
    return
  end
  local server_state = workflow._states()[roots.lsp_root]
  if not server_state then
    health.info 'No clangd workflow has run for this root in the current session'
    return
  end
  local running = {}
  for _, stage in ipairs { 'compile_commands', 'build' } do
    if server_state.stages[stage].state == 'waiting' then
      running[#running + 1] = stage
    end
  end
  if #running > 0 then
    health.info(
      ('clangd preparation revision %d is running: %s'):format(
        server_state.revision,
        table.concat(running, ', ')
      )
    )
  else
    health.info(('clangd preparation revision: %d'):format(server_state.revision))
  end
end

function M.check()
  health.start 'arcadia-lspconfig.nvim'

  if version_ok() then
    local version = vim.version()
    health.ok(('Neovim %d.%d.%d is supported'):format(version.major, version.minor, version.patch))
  else
    health.error 'Neovim 0.11.3 or newer is required'
  end

  for _, server in ipairs { 'clangd', 'pyright' } do
    local definition = ('lsp/%s.lua'):format(server)
    if #vim.api.nvim_get_runtime_file(definition, false) > 0 then
      health.ok(('nvim-lspconfig provides %s'):format(definition))
    else
      health.error(('nvim-lspconfig does not provide %s'):format(definition))
    end
  end

  local bufnr = project_buffer()
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

  if vim.bo[bufnr].filetype == 'python' then
    check_pyright(roots)
  else
    check_clangd(roots)
  end
end

return M
