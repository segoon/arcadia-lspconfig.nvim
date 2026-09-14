local M = {}

local defaults = {
  servers = { clangd = {}, pyright = {} },
  jobs = { cancel_on_buff_exit = true, timeout_ms = nil },
  log = { level = 'warn' },
}

local configured = false
local options
local workflows = {}

---@param value table
---@param allowed table<string, boolean>
---@param label string
local function reject_unknown(value, allowed, label)
  for key in pairs(value) do
    if not allowed[key] then
      error(('arcadia-lspconfig: unknown %s option: %s'):format(label, key), 3)
    end
  end
end

---@param user_options? table
---@return table
local function validate_options(user_options)
  vim.validate('options', user_options, 'table', true)
  user_options = user_options or {}
  reject_unknown(user_options, { servers = true, jobs = true, log = true }, 'top-level')
  vim.validate('servers', user_options.servers, 'table', true)
  vim.validate('jobs', user_options.jobs, 'table', true)
  vim.validate('log', user_options.log, 'table', true)

  local result = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_options)
  reject_unknown(result.servers, { clangd = true, pyright = true }, 'server')
  reject_unknown(result.jobs, { cancel_on_buff_exit = true, timeout_ms = true }, 'jobs')
  reject_unknown(result.log, { level = true }, 'log')

  if result.servers.clangd ~= false then
    vim.validate('servers.clangd', result.servers.clangd, 'table')
    reject_unknown(result.servers.clangd, {}, 'servers.clangd')
  end
  if result.servers.pyright ~= false then
    vim.validate('servers.pyright', result.servers.pyright, 'table')
    reject_unknown(result.servers.pyright, {}, 'servers.pyright')
  end
  vim.validate('jobs.cancel_on_buff_exit', result.jobs.cancel_on_buff_exit, 'boolean')
  vim.validate('jobs.timeout_ms', result.jobs.timeout_ms, 'number', true)
  if result.jobs.timeout_ms ~= nil and result.jobs.timeout_ms <= 0 then
    error('arcadia-lspconfig: jobs.timeout_ms must be positive', 3)
  end
  vim.validate('log.level', result.log.level, 'string')
  if not vim.tbl_contains({ 'debug', 'info', 'warn', 'error', 'off' }, result.log.level) then
    error('arcadia-lspconfig: log.level must be debug, info, warn, error, or off', 3)
  end
  return result
end

---@param validated_options table
local function validate_environment(validated_options)
  local version = vim.version()
  if version.major == 0 and (version.minor < 11 or (version.minor == 11 and version.patch < 3)) then
    error('arcadia-lspconfig requires Neovim 0.11.3 or newer', 3)
  end
  for _, server in ipairs { 'clangd', 'pyright' } do
    if
      validated_options.servers[server] ~= false
      and #vim.api.nvim_get_runtime_file(('lsp/%s.lua'):format(server), false) == 0
    then
      error(('arcadia-lspconfig requires nvim-lspconfig lsp/%s.lua'):format(server), 3)
    end
  end
end

---@param bufnr integer
---@return table?
local function workflow_for_buffer(bufnr)
  local filetype = vim.bo[bufnr].filetype
  for _, server in ipairs { 'clangd', 'pyright' } do
    local workflow = workflows[server]
    local base = require('arcadia-lspconfig.config').base(server)
    if workflow and base and vim.tbl_contains(base.filetypes or {}, filetype) then
      return workflow
    end
  end
  return nil
end

---@param server string
---@param workflow table
local function install_server(server, workflow)
  local config = require 'arcadia-lspconfig.config'
  local base = vim.lsp.config[server]
  if not base then
    error(('arcadia-lspconfig: nvim-lspconfig has no %s configuration'):format(server), 3)
  end
  config.capture(server, base)
  vim.lsp.config(server, {
    -- Neovim validates cmd before calling root_dir. A functional wrapper lets
    -- Arcadia replace a missing system executable with checkout-local ya while
    -- preserving the original command for buffers outside Arcadia.
    cmd = function(dispatchers, client_config)
      if type(base.cmd) == 'function' then
        return base.cmd(dispatchers, client_config)
      end
      return vim.lsp.rpc.start(base.cmd, dispatchers, {
        cwd = client_config.cmd_cwd,
        env = client_config.cmd_env,
        detached = client_config.detached,
      })
    end,
    root_dir = function(bufnr, on_dir)
      local context = workflow.context(bufnr)
      if context then
        workflow.activate(bufnr, context)
      else
        config.delegate_root(base, bufnr, on_dir)
      end
    end,
  })
end

local function create_commands()
  vim.api.nvim_create_user_command('LspRefreshArcadia', function()
    local ok, err = M.refresh(0)
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = 'arcadia-lspconfig.nvim' })
    end
  end, { desc = 'Refresh Arcadia LSP preparation for the current buffer' })

  vim.api.nvim_create_user_command('ArcadiaLspStatus', function()
    local value = M.status(0)
    vim.notify(value and vim.inspect(value) or 'No Arcadia LSP state for the current buffer', nil, {
      title = 'arcadia-lspconfig.nvim',
    })
  end, { desc = 'Show Arcadia LSP status for the current buffer' })

  vim.api.nvim_create_user_command('ArcadiaLspRestart', function()
    local workflow = workflow_for_buffer(vim.api.nvim_get_current_buf())
    if not workflow then
      vim.notify(
        'no enabled Arcadia LSP integration applies to the current buffer',
        vim.log.levels.WARN,
        {
          title = 'arcadia-lspconfig.nvim',
        }
      )
      return
    end
    local ok, err = workflow.restart(0)
    if not ok then
      vim.notify(err, vim.log.levels.WARN, {
        title = 'arcadia-lspconfig.nvim',
      })
    end
  end, { desc = 'Restart the Arcadia LSP client for the current buffer' })
end

---@param user_options? table
function M.setup(user_options)
  if configured then
    error('arcadia-lspconfig.setup() may only be called once', 2)
  end
  options = validate_options(user_options)
  validate_environment(options)
  configured = true

  require('arcadia-lspconfig.log').configure(options.log.level)
  require('arcadia-lspconfig.jobs').setup(options.jobs)

  ---@return table
  local function make_api()
    local api = {
      root = require 'arcadia-lspconfig.root',
      paths = require 'arcadia-lspconfig.paths',
      cache = require 'arcadia-lspconfig.cache',
      pyright_cache = require 'arcadia-lspconfig.pyright_cache',
      config = require 'arcadia-lspconfig.config',
      jobs = require 'arcadia-lspconfig.jobs',
      clients = require 'arcadia-lspconfig.clients',
      status = require 'arcadia-lspconfig.status',
      notify = require 'arcadia-lspconfig.notify',
      log = require 'arcadia-lspconfig.log',
      options = options,
    }
    return api
  end

  for _, server in ipairs { 'clangd', 'pyright' } do
    if options.servers[server] ~= false then
      workflows[server] = require('arcadia-lspconfig.servers.' .. server)(make_api())
      install_server(server, workflows[server])
    end
  end
  create_commands()
end

---@param bufnr? integer
---@return ArcadiaLspStatus?
function M.status(bufnr)
  bufnr = bufnr or 0
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  return require('arcadia-lspconfig.status').get(bufnr)
end

---@param bufnr? integer
---@return string
function M.statusline(bufnr)
  bufnr = bufnr or 0
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  return require('arcadia-lspconfig.status').line(bufnr)
end

---@param bufnr? integer
---@return boolean?, string?
function M.refresh(bufnr)
  bufnr = bufnr or 0
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local workflow = workflow_for_buffer(bufnr)
  if not workflow then
    return nil, 'no enabled Arcadia LSP integration applies to the current buffer'
  end
  return workflow.refresh(bufnr)
end

---@return table
function M._state()
  return { configured = configured, options = options, workflows = workflows }
end

return M
