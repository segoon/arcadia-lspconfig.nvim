local M = {}

---@param definition ArcadiaLspServerDefinition
---@param api table
---@return ArcadiaLspWorkflow
function M.new(definition, api)
  local server = definition.name
  local workflow = {}

  ---@param bufnr integer
  ---@return table?
  function workflow.context(bufnr)
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    return definition.context(bufnr)
  end

  ---@param root string
  ---@return string[]?, string?
  local function command(root)
    local cmd = definition.command(root)
    if vim.fn.executable(cmd[1]) == 1 then
      return cmd
    end
    return nil, ('%s requires executable: %s'):format(server, cmd[1])
  end

  ---@param context table
  ---@return boolean?, string?
  local function available(context)
    api.status.associate(context.bufnr, context.arcadia_root, context.lsp_root, server)
    local cmd, err = command(context.lsp_root)
    if not cmd then
      api.status.set(context.lsp_root, server, { state = 'error', message = err })
      api.notify.warn_once(context.lsp_root, server, 'missing_executable', err)
      return nil, err
    end
    api.clients.detach_wrong_root(context.bufnr, server, context.lsp_root)
    return true
  end

  ---@param bufnr integer
  ---@param on_dir fun(root_dir: string)
  function workflow.root_dir(bufnr, on_dir)
    local context = workflow.context(bufnr)
    if context and available(context) then
      on_dir(context.lsp_root)
    end
  end

  ---@param dispatchers table
  ---@param config vim.lsp.ClientConfig
  ---@return vim.lsp.rpc.PublicClient?
  function workflow.cmd(dispatchers, config)
    local cmd, err = command(config.root_dir)
    if not cmd then
      api.status.set(config.root_dir, server, { state = 'error', message = err })
      api.notify.warn_once(config.root_dir, server, 'missing_executable', err)
      return nil
    end
    local client = vim.lsp.rpc.start(cmd, dispatchers, {
      cwd = config.cmd_cwd,
      env = config.cmd_env,
      detached = config.detached,
    })
    api.status.set(config.root_dir, server, {
      state = client and 'ready' or 'error',
      message = not client and ('%s failed to start; see :LspLog'):format(server) or nil,
    })
    return client
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.restart(bufnr)
    local context = workflow.context(bufnr)
    if not context then
      return nil, ('no %s project applies to the current buffer'):format(server)
    end
    local ok, err = available(context)
    if not ok then
      return nil, err
    end
    api.status.set(context.lsp_root, server, { state = 'idle' })
    api.clients.restart(context.lsp_root, server, { context.bufnr })
    return true
  end

  workflow.refresh = workflow.restart

  ---@param context table
  ---@return ArcadiaLspHealthEntry[]
  function workflow.health(context)
    local cmd, err = command(context.lsp_root)
    return { { level = cmd and 'ok' or 'warn', message = err or table.concat(cmd, ' ') } }
  end

  return workflow
end

return M
