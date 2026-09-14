local SERVER = 'ty'

---@param api table
---@return ArcadiaLspWorkflow
return function(api)
  local workflow = {}

  ---@param bufnr integer
  ---@return table?
  function workflow.context(bufnr)
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local roots = api.root.find(path)
    if not roots.arcadia_root then
      return nil
    end
    return {
      bufnr = bufnr,
      path = path,
      arcadia_root = roots.arcadia_root,
      lsp_root = roots.lsp_root,
    }
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return boolean?, string?
  function workflow.activate(bufnr, context)
    context = context or workflow.context(bufnr)
    if not context then
      return nil, 'buffer is outside Arcadia'
    end
    for _, client in
      ipairs(vim.lsp.get_clients { bufnr = bufnr, name = SERVER, _uninitialized = true })
    do
      vim.lsp.buf_detach_client(bufnr, client.id)
    end
    return true
  end

  ---@return nil, string
  local function disabled()
    return nil, 'ty is disabled for Arcadia buffers'
  end

  workflow.refresh = disabled
  workflow.restart = disabled

  ---@return ArcadiaLspHealthEntry[]
  function workflow.health()
    return { { level = 'info', message = 'ty is disabled for Arcadia buffers' } }
  end

  return workflow
end
