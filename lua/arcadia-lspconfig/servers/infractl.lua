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
    local directory = vim.fs.dirname(path)
    while directory do
      if
        vim.uv.fs_stat(directory .. '/a.yaml') or vim.uv.fs_stat(directory .. '/.arcadia.root')
      then
        return {
          bufnr = bufnr,
          path = path,
          arcadia_root = roots.arcadia_root,
          lsp_root = directory,
        }
      end
      if directory == roots.arcadia_root then
        break
      end
      directory = vim.fs.dirname(directory)
    end
  end

  ---@param bufnr integer
  ---@param context? table
  ---@param restart? boolean
  ---@return boolean?, string?
  local function start(bufnr, context, restart)
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
    api.config.extend(context.lsp_root, SERVER, { cmd = { ya, 'tool', 'infractl', 'lsp' } })
    api.clients.detach_wrong_root(context.bufnr, SERVER, context.lsp_root)
    if restart then
      api.clients.restart(context.lsp_root, SERVER, { context.bufnr })
    elseif not api.clients.start(context.lsp_root, SERVER, { context.bufnr }) then
      local message = 'infractl failed to start; see :LspLog'
      api.status.set(context.lsp_root, SERVER, { state = 'error', message = message })
      return nil, message
    end
    api.status.set(context.lsp_root, SERVER, { state = 'ready' })
    return true
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return boolean?, string?
  function workflow.activate(bufnr, context)
    return start(bufnr, context)
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.restart(bufnr)
    return start(bufnr, nil, true)
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
