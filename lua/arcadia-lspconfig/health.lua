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

---@param entries ArcadiaLspHealthEntry[]
local function render(entries)
  for _, entry in ipairs(entries) do
    local report = health[entry.level]
    if type(report) == 'function' then
      report(entry.message)
    else
      health.error(('Invalid health level: %s'):format(vim.inspect(entry.level)))
    end
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

  local plugin = require 'arcadia-lspconfig'
  local runtime_state = plugin._state()
  for _, definition in ipairs(runtime_state.definitions) do
    if not runtime_state.options or runtime_state.options.servers[definition.name] ~= false then
      local config_file = ('lsp/%s.lua'):format(definition.name)
      if #vim.api.nvim_get_runtime_file(config_file, false) > 0 then
        health.ok(('nvim-lspconfig provides %s'):format(config_file))
      else
        health.error(('nvim-lspconfig does not provide %s'):format(config_file))
      end
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

  local workflow = plugin._workflow(bufnr)
  if not workflow then
    health.info 'No enabled Arcadia LSP integration applies to the current buffer'
    return
  end
  local context = workflow.context(bufnr)
  if not context then
    health.info 'The applicable Arcadia LSP workflow has no context for the current buffer'
    return
  end
  render(workflow.health(context))
end

return M
