local SERVER = 'ya-make-lsp'
local SOURCE = 'devtools/ide/vscode-yandex-arc/ya-make-lsp'

---@param api table
---@return ArcadiaLspWorkflow
return function(api)
  ---@class ArcadiaYamakeRootState
  ---@field arcadia_root string
  ---@field lsp_root string
  ---@field buffers table<integer, boolean>
  ---@field configured boolean

  ---@class ArcadiaYamakeState
  ---@field data_dir string
  ---@field roots table<string, ArcadiaYamakeRootState>
  ---@field running boolean
  ---@field generation integer
  ---@field stage string
  ---@field job_key? string
  ---@field transaction? ArcadiaYamakeTransaction
  ---@field had_valid_install boolean

  vim.filetype.add { filename = { ['ya.make'] = 'yamake' } }

  ---@type ArcadiaYamakeState
  local state = {
    data_dir = api.paths.shared(SERVER),
    roots = {},
    running = false,
    generation = 0,
    stage = 'idle',
    had_valid_install = false,
  }
  local workflow = {}

  ---@param bufnr integer
  ---@return table?
  function workflow.context(bufnr)
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.fs.basename(name) ~= 'ya.make' then
      return nil
    end
    local roots = api.root.find(name)
    if not roots.arcadia_root or not roots.lsp_root then
      return nil
    end
    return {
      bufnr = bufnr,
      path = name,
      arcadia_root = roots.arcadia_root,
      lsp_root = roots.lsp_root,
      data_dir = state.data_dir,
    }
  end

  ---@param context table
  ---@return ArcadiaYamakeRootState
  local function root_state(context)
    local root = state.roots[context.lsp_root]
    if not root then
      root = {
        arcadia_root = context.arcadia_root,
        lsp_root = context.lsp_root,
        buffers = {},
        configured = false,
      }
      state.roots[context.lsp_root] = root
    end
    return root
  end

  ---@param root ArcadiaYamakeRootState
  ---@return integer[]
  local function valid_buffers(root)
    local buffers = {}
    for bufnr in pairs(root.buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        local context = workflow.context(bufnr)
        if context and context.lsp_root == root.lsp_root then
          buffers[#buffers + 1] = bufnr
        end
      end
    end
    return buffers
  end

  ---@param root ArcadiaYamakeRootState
  local function configure(root)
    if root.configured then
      return
    end
    api.config.extend(root.lsp_root, SERVER, {
      cmd = { 'node', api.cache.script_path(state.data_dir), '--stdio' },
    })
    root.configured = true
  end

  ---@param value ArcadiaLspServerStatus
  local function publish(value)
    value.revision = state.generation
    for _, root in pairs(state.roots) do
      api.status.set(root.lsp_root, SERVER, value)
    end
  end

  ---@param root ArcadiaYamakeRootState
  local function start_root(root)
    local buffers = valid_buffers(root)
    if #buffers > 0 then
      api.clients.start(root.lsp_root, SERVER, buffers)
    end
  end

  local function start_all()
    for _, root in pairs(state.roots) do
      start_root(root)
    end
  end

  local function restart_all()
    for _, root in pairs(state.roots) do
      local buffers = valid_buffers(root)
      if #buffers > 0 then
        api.clients.restart(root.lsp_root, SERVER, buffers)
      end
    end
  end

  ---@param code string
  ---@param message string
  local function fail(code, message)
    if state.transaction then
      local restored, restore_error = api.cache.rollback(state.transaction)
      state.transaction = nil
      if not restored then
        message = message .. '; ' .. restore_error
      end
    end
    state.running = false
    state.job_key = nil
    state.stage = 'error'
    local usable = api.cache.is_valid(state.data_dir)
    for _, root in pairs(state.roots) do
      api.notify.warn_once(root.lsp_root, SERVER, code, message)
    end
    publish {
      state = usable and 'warning' or 'error',
      stage = state.stage,
      message = message,
    }
  end

  ---@param stage string
  ---@param context table
  ---@param command string[]
  ---@param cwd string
  ---@param on_success fun(result: ArcadiaLspJobResult)
  ---@return boolean?, string?
  local function start_job(stage, context, command, cwd, on_success)
    state.stage = stage
    state.job_key = SERVER .. '\0global\0' .. stage
    publish { state = 'waiting', stage = stage, message = ('Preparing %s'):format(SERVER) }
    local key = state.job_key
    local job, start_error = api.jobs.start(key, {
      cmd = command,
      cwd = cwd,
      bufnr = context.bufnr,
      on_exit = function(result)
        if result.timed_out then
          fail(stage .. '_timeout', ('%s timed out'):format(stage))
        elseif result.cancelled then
          fail(stage .. '_cancelled', ('%s was cancelled'):format(stage))
        elseif result.code ~= 0 then
          local detail = (result.stderr or ''):gsub('%s+$', '')
          local message = ('%s failed'):format(stage:gsub('_', ' '))
          if detail ~= '' then
            message = message .. ': ' .. detail
          end
          fail(stage .. '_failed', message)
        else
          on_success(result)
        end
      end,
    })
    if start_error then
      local message = ('cannot start %s: %s'):format(stage:gsub('_', ' '), start_error)
      fail(stage .. '_start_failed', message)
      return nil, message
    end
    for _, root in pairs(state.roots) do
      for _, bufnr in ipairs(valid_buffers(root)) do
        api.jobs.add_interest(key, bufnr)
      end
    end
    return job and true or nil
  end

  ---@param context table
  ---@param revision string
  local function start_build(context, revision)
    start_job('build', context, { 'npm', 'run', 'build' }, state.data_dir, function()
      local committed, commit_error = api.cache.commit(state.transaction, revision)
      if not committed then
        fail('install_failed', commit_error)
        return
      end
      state.transaction = nil
      state.running = false
      state.job_key = nil
      state.stage = 'ready'
      publish { state = 'ready', stage = 'install' }
      if state.had_valid_install then
        restart_all()
      else
        start_all()
      end
    end)
  end

  ---@param context table
  ---@param revision string
  local function start_npm_install(context, revision)
    start_job('npm_install', context, { 'npm', 'install' }, state.data_dir, function()
      start_build(context, revision)
    end)
  end

  ---@param context table
  ---@param revision string
  local function start_export(context, revision)
    local transaction, prepare_error = api.cache.prepare(state.data_dir, state.generation)
    if not transaction then
      fail('install_prepare_failed', prepare_error)
      return
    end
    state.transaction = transaction
    local command = { 'arc', 'export', 'trunk', SOURCE, '--to', state.data_dir }
    start_job('export', context, command, context.arcadia_root, function()
      start_npm_install(context, revision)
    end)
  end

  ---@param context table
  ---@return boolean?, string?
  local function check(context)
    if state.running then
      if state.job_key then
        api.jobs.add_interest(state.job_key, context.bufnr)
      end
      return true
    end
    if vim.fn.executable 'arc' ~= 1 then
      local message = 'arc is not executable'
      fail('missing_arc', message)
      return nil, message
    end
    if vim.fn.executable 'node' ~= 1 or vim.fn.executable 'npm' ~= 1 then
      local message = 'node and npm are required to install ya-make-lsp'
      fail('missing_node', message)
      return nil, message
    end

    state.running = true
    state.generation = state.generation + 1
    local command = { 'arc', 'log', '-n1', 'trunk', '--oneline', SOURCE }
    return start_job('version_check', context, command, context.arcadia_root, function(result)
      local revision = api.cache.parse_revision(result.stdout)
      if not revision then
        fail('invalid_revision', 'arc log returned no full ya-make-lsp revision')
        return
      end
      if api.cache.is_valid(state.data_dir) and api.cache.revision(state.data_dir) == revision then
        state.running = false
        state.job_key = nil
        state.stage = 'ready'
        publish { state = 'ready', stage = 'version_check' }
        return
      end
      state.had_valid_install = api.cache.is_valid(state.data_dir)
      start_export(context, revision)
    end)
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return boolean?, string?
  function workflow.activate(bufnr, context)
    context = context or workflow.context(bufnr)
    if not context then
      return nil, 'buffer is not an Arcadia ya.make file'
    end
    local root = root_state(context)
    root.buffers[bufnr] = true
    api.status.associate(bufnr, context.arcadia_root, context.lsp_root, SERVER)
    api.clients.detach_wrong_root(bufnr, SERVER, context.lsp_root)
    configure(root)
    if api.cache.is_valid(state.data_dir) then
      start_root(root)
    end
    return check(context)
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.refresh(bufnr)
    local context = workflow.context(bufnr)
    if not context then
      return nil, 'current buffer is not an Arcadia ya.make file'
    end
    local root = root_state(context)
    root.buffers[bufnr] = true
    api.status.associate(bufnr, context.arcadia_root, context.lsp_root, SERVER)
    configure(root)
    return check(context)
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.restart(bufnr)
    local context = workflow.context(bufnr)
    if not context then
      return nil, 'current buffer is not an Arcadia ya.make file'
    end
    if not api.cache.is_valid(state.data_dir) then
      return nil, ('no valid ya-make-lsp installation is available: %s'):format(state.data_dir)
    end
    local root = root_state(context)
    root.buffers[bufnr] = true
    configure(root)
    api.clients.restart(root.lsp_root, SERVER, valid_buffers(root))
    return true
  end

  ---@param context table
  ---@return ArcadiaLspHealthEntry[]
  function workflow.health(context)
    local entries = {}
    for _, executable in ipairs { 'arc', 'node', 'npm' } do
      local available = vim.fn.executable(executable) == 1
      entries[#entries + 1] = {
        level = available and 'ok' or 'error',
        message = available and (executable .. ' is executable')
          or (executable .. ' is not executable'),
      }
    end
    entries[#entries + 1] = {
      level = api.cache.is_valid(state.data_dir) and 'ok' or 'info',
      message = api.cache.is_valid(state.data_dir)
          and ('Installed ya-make-lsp revision: %s'):format(api.cache.revision(state.data_dir))
        or ('No valid ya-make-lsp installation exists: %s'):format(state.data_dir),
    }
    entries[#entries + 1] = {
      level = 'info',
      message = state.running and ('ya-make-lsp update stage: %s'):format(state.stage)
        or 'ya-make-lsp update is idle',
    }
    return entries
  end

  ---@return ArcadiaYamakeState
  function workflow._state()
    return state
  end

  return workflow
end
