local SERVER = 'infractl'

---@param api table
---@return ArcadiaLspWorkflow
return function(api)
  vim.filetype.add { extension = { star = 'starlark' } }
  local workflow = {}

  ---@param bufnr integer
  ---@return table?
  function workflow.context(bufnr)
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local name = vim.fs.basename(path)
    if not (name:match '%.star$' or name == 'i.yaml' or name:match '^i%..*%.yaml$') then
      return nil
    end
    local roots = api.root.find(path)
    if not roots.arcadia_root then
      return nil
    end
    local marker = vim.fs.find({ 'a.yaml', '.arcadia.root' }, {
      path = vim.fs.dirname(path),
      upward = true,
      stop = vim.fs.dirname(roots.arcadia_root),
    })[1]
    if marker then
      return {
        bufnr = bufnr,
        path = path,
        arcadia_root = roots.arcadia_root,
        lsp_root = vim.fs.dirname(marker),
      }
    end
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return table?, string?
  local function configure(bufnr, context)
    context = context or workflow.context(bufnr)
    if not context then
      return nil, 'buffer is not an Arcadia infractl file with an a.yaml or .arcadia.root ancestor'
    end
    local ya = vim.fs.joinpath(context.arcadia_root, 'ya')
    api.status.associate(context.bufnr, context.arcadia_root, context.lsp_root, SERVER)
    if not api.is_executable(ya) then
      local message = ('infractl requires executable Arcadia ya: %s'):format(ya)
      api.status.set(context.lsp_root, SERVER, { state = 'error', message = message })
      api.notify.warn_once(context.lsp_root, SERVER, 'missing_ya', message)
      return nil, message
    end
    if api.config.revision(context.lsp_root, SERVER) == 0 then
      api.config.extend(context.lsp_root, SERVER, { cmd = { ya, 'tool', 'infractl', 'lsp' } })
    end
    api.clients.detach_wrong_root(context.bufnr, SERVER, context.lsp_root)
    return context
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return boolean?, string?
  function workflow.activate(bufnr, context)
    local prepared, err = configure(bufnr, context)
    if not prepared then
      return nil, err
    end
    local started = api.clients.start(prepared.lsp_root, SERVER, { prepared.bufnr })
    local message = not started and 'infractl failed to start; see :LspLog' or nil
    api.status.set(
      prepared.lsp_root,
      SERVER,
      { state = started and 'ready' or 'error', message = message }
    )
    return started and true or nil, message
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.restart(bufnr)
    local context, err = configure(bufnr)
    if not context then
      return nil, err
    end
    api.status.set(context.lsp_root, SERVER, { state = 'idle' })
    api.clients.restart(context.lsp_root, SERVER, { context.bufnr })
    return true
  end

  workflow.refresh = workflow.restart

  ---@param context table
  ---@return ArcadiaLspHealthEntry[]
  function workflow.health(context)
    local ya = vim.fs.joinpath(context.arcadia_root, 'ya')
    return {
      {
        level = api.is_executable(ya) and 'ok' or 'warn',
        message = ('infractl command: %s tool infractl lsp'):format(ya),
      },
    }
  end

  return workflow
end
