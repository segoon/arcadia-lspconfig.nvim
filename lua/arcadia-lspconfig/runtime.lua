local Runtime = {}

---@class ArcadiaLspServerDefinition
---@field name string
---@field default_options table
---@field allowed_options table<string, string>
---@field route_commands? boolean
---@field auto_enable? boolean
---@field config? vim.lsp.Config
---@field create fun(api: table): ArcadiaLspWorkflow

---@class ArcadiaLspWorkflow
---@field context fun(bufnr: integer): table?
---@field activate fun(bufnr: integer, context?: table): boolean?, string?
---@field refresh fun(bufnr: integer): boolean?, string?
---@field restart fun(bufnr: integer): boolean?, string?
---@field health fun(context: table): ArcadiaLspHealthEntry[]

---@class ArcadiaLspHealthEntry
---@field level 'ok'|'info'|'warn'|'error'
---@field message string

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

---@param definitions ArcadiaLspServerDefinition[]
---@return table<string, ArcadiaLspServerDefinition>
local function validate_definitions(definitions)
  vim.validate('server definitions', definitions, 'table')
  if not vim.islist(definitions) then
    error('arcadia-lspconfig: server definitions must be a list', 3)
  end
  local by_name = {}
  for index, definition in ipairs(definitions) do
    vim.validate(('server definition %d'):format(index), definition, 'table')
    vim.validate(('server definition %d.name'):format(index), definition.name, 'string')
    vim.validate(
      ('server definition %s.default_options'):format(definition.name),
      definition.default_options,
      'table'
    )
    vim.validate(
      ('server definition %s.allowed_options'):format(definition.name),
      definition.allowed_options,
      'table'
    )
    for option, expected_type in pairs(definition.allowed_options) do
      vim.validate(
        ('server definition %s.allowed_options.%s'):format(definition.name, option),
        expected_type,
        'string'
      )
    end
    vim.validate(
      ('server definition %s.create'):format(definition.name),
      definition.create,
      'function'
    )
    vim.validate(
      ('server definition %s.route_commands'):format(definition.name),
      definition.route_commands,
      'boolean',
      true
    )
    vim.validate(
      ('server definition %s.auto_enable'):format(definition.name),
      definition.auto_enable,
      'boolean',
      true
    )
    vim.validate(
      ('server definition %s.config'):format(definition.name),
      definition.config,
      'table',
      true
    )
    if by_name[definition.name] then
      error(('arcadia-lspconfig: duplicate server definition: %s'):format(definition.name), 3)
    end
    by_name[definition.name] = definition
  end
  return by_name
end

---@param definitions ArcadiaLspServerDefinition[]
---@return table
function Runtime.new(definitions)
  local definitions_by_name = validate_definitions(definitions)
  local defaults = {
    servers = {},
    jobs = { cancel_on_buff_exit = true, timeout_ms = nil },
    log = { level = 'warn' },
  }
  for _, definition in ipairs(definitions) do
    defaults.servers[definition.name] = vim.deepcopy(definition.default_options)
  end

  local M = {}
  local configured = false
  local options
  ---@type table<string, ArcadiaLspWorkflow>
  local workflows = {}
  local active = {}

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
    local allowed_servers = {}
    for name in pairs(definitions_by_name) do
      allowed_servers[name] = true
    end
    reject_unknown(result.servers, allowed_servers, 'server')
    reject_unknown(result.jobs, { cancel_on_buff_exit = true, timeout_ms = true }, 'jobs')
    reject_unknown(result.log, { level = true }, 'log')

    for _, definition in ipairs(definitions) do
      local server_options = result.servers[definition.name]
      if server_options ~= false then
        vim.validate(('servers.%s'):format(definition.name), server_options, 'table')
        reject_unknown(
          server_options,
          definition.allowed_options,
          ('servers.%s'):format(definition.name)
        )
        for option, expected_type in pairs(definition.allowed_options) do
          vim.validate(
            ('servers.%s.%s'):format(definition.name, option),
            server_options[option],
            expected_type,
            true
          )
        end
      end
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
    if
      version.major == 0 and (version.minor < 11 or (version.minor == 11 and version.patch < 3))
    then
      error('arcadia-lspconfig requires Neovim 0.11.3 or newer', 3)
    end
    for _, definition in ipairs(definitions) do
      if validated_options.servers[definition.name] ~= false then
        local config_file = ('lsp/%s.lua'):format(definition.name)
        if not definition.config and #vim.api.nvim_get_runtime_file(config_file, false) == 0 then
          error(('arcadia-lspconfig requires an LSP configuration %s'):format(config_file), 3)
        end
      end
    end
  end

  ---@param bufnr integer
  ---@return ArcadiaLspWorkflow?, ArcadiaLspServerDefinition?, string?
  local function workflow_for_buffer(bufnr)
    local filetype = vim.bo[bufnr].filetype
    local matches = {}
    for _, entry in ipairs(active) do
      if entry.definition.route_commands ~= false then
        local base = require('arcadia-lspconfig.config').base(entry.definition.name)
        if
          vim.lsp.is_enabled(entry.definition.name)
          and base
          and vim.tbl_contains(base.filetypes or {}, filetype)
        then
          matches[#matches + 1] = entry
        end
      end
    end
    if #matches == 1 then
      return matches[1].workflow, matches[1].definition
    end
    if #matches > 1 then
      local names = vim.tbl_map(function(entry)
        return entry.definition.name
      end, matches)
      table.sort(names)
      return nil,
        nil,
        ('multiple enabled Arcadia LSP integrations apply to this buffer: %s'):format(
          table.concat(names, ', ')
        )
    end
    return nil, nil, nil
  end

  ---@param definition ArcadiaLspServerDefinition
  ---@param workflow ArcadiaLspWorkflow
  local function install_server(definition, workflow)
    local config = require 'arcadia-lspconfig.config'
    local server = definition.name
    if definition.config then
      vim.lsp.config(server, definition.config)
    end
    local base = vim.lsp.config[server]
    if not base then
      error(('arcadia-lspconfig: no %s LSP configuration is available'):format(server), 3)
    end
    config.capture(server, base)
    vim.lsp.config(server, {
      -- Defer command startup until the workflow has selected and prepared the
      -- root-specific configuration, while preserving the base command elsewhere.
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
    vim.api.nvim_create_user_command('LspArcadiaRefresh', function()
      local ok, err = M.refresh(0)
      if not ok then
        vim.notify(err, vim.log.levels.WARN, { title = 'arcadia-lspconfig.nvim' })
      end
    end, { desc = 'Refresh Arcadia LSP preparation for the current buffer' })

    vim.api.nvim_create_user_command('LspArcadiaStatus', function()
      local value = M.status(0)
      vim.notify(
        value and vim.inspect(value) or 'No Arcadia LSP state for the current buffer',
        nil,
        {
          title = 'arcadia-lspconfig.nvim',
        }
      )
    end, { desc = 'Show Arcadia LSP status for the current buffer' })

    vim.api.nvim_create_user_command('LspArcadiaRestart', function()
      local workflow, _, selection_error = workflow_for_buffer(vim.api.nvim_get_current_buf())
      if not workflow then
        vim.notify(
          selection_error or 'no enabled Arcadia LSP integration applies to the current buffer',
          vim.log.levels.WARN,
          { title = 'arcadia-lspconfig.nvim' }
        )
        return
      end
      local ok, err = workflow.restart(0)
      if not ok then
        vim.notify(err, vim.log.levels.WARN, { title = 'arcadia-lspconfig.nvim' })
      end
    end, { desc = 'Restart the Arcadia LSP client for the current buffer' })
  end

  ---@return table
  local function make_api()
    return {
      root = require 'arcadia-lspconfig.root',
      paths = require 'arcadia-lspconfig.paths',
      config = require 'arcadia-lspconfig.config',
      jobs = require 'arcadia-lspconfig.jobs',
      clients = require 'arcadia-lspconfig.clients',
      status = require 'arcadia-lspconfig.status',
      notify = require 'arcadia-lspconfig.notify',
      log = require 'arcadia-lspconfig.log',
      options = options,
    }
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

    for _, definition in ipairs(definitions) do
      if options.servers[definition.name] ~= false then
        local workflow = definition.create(make_api())
        workflows[definition.name] = workflow
        active[#active + 1] = { definition = definition, workflow = workflow }
        install_server(definition, workflow)
        if definition.auto_enable then
          vim.lsp.enable(definition.name)
        end
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
    local workflow, _, selection_error = workflow_for_buffer(bufnr)
    if not workflow then
      return nil,
        selection_error or 'no enabled Arcadia LSP integration applies to the current buffer'
    end
    return workflow.refresh(bufnr)
  end

  ---@param bufnr integer
  ---@return ArcadiaLspWorkflow?, ArcadiaLspServerDefinition?, string?
  function M._workflow(bufnr)
    return workflow_for_buffer(bufnr)
  end

  ---@return table
  function M._state()
    return {
      configured = configured,
      options = options,
      workflows = workflows,
      definitions = definitions,
      active = active,
    }
  end

  return M
end

return Runtime
