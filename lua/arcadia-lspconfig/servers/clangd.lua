local SERVER = 'clangd'

---@param api table
---@return table
return function(api)
  ---@class ArcadiaClangdState
  ---@field arcadia_root string
  ---@field lsp_root string
  ---@field data_dir string
  ---@field ya_path string
  ---@field buffers table<integer, boolean>
  ---@field waiting table<integer, boolean>
  ---@field attempted boolean
  ---@field running boolean
  ---@field revision integer
  ---@field command_configured boolean
  ---@field database_configured boolean
  ---@field temporary_path? string

  ---@type table<string, ArcadiaClangdState>
  local states = {}
  local workflow = {}

  ---@param bufnr integer
  ---@return table?
  function workflow.context(bufnr)
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    local roots = api.root.find(name)
    if not roots.arcadia_root or not roots.lsp_root then
      return nil
    end
    return {
      bufnr = bufnr,
      path = name,
      arcadia_root = roots.arcadia_root,
      lsp_root = roots.lsp_root,
      data_dir = api.paths.data(roots.lsp_root, SERVER),
    }
  end

  ---@param context table
  ---@return ArcadiaClangdState
  local function state_for(context)
    local state = states[context.lsp_root]
    if not state then
      state = {
        arcadia_root = context.arcadia_root,
        lsp_root = context.lsp_root,
        data_dir = context.data_dir,
        ya_path = vim.fs.joinpath(context.arcadia_root, 'ya'),
        buffers = {},
        waiting = {},
        attempted = false,
        running = false,
        revision = 0,
        command_configured = false,
        database_configured = false,
      }
      states[context.lsp_root] = state
    end
    return state
  end

  ---@param state ArcadiaClangdState
  local function configure_command(state)
    if state.command_configured then
      return
    end
    api.config.extend(state.lsp_root, SERVER, { cmd = { state.ya_path, 'tool', 'clangd' } })
    state.command_configured = true
  end

  ---@param state ArcadiaClangdState
  local function configure_database(state)
    if state.database_configured then
      return
    end
    api.config.extend(state.lsp_root, SERVER, {
      init_options = { compilationDatabasePath = state.data_dir },
    })
    state.database_configured = true
  end

  ---@param state ArcadiaClangdState
  ---@return integer[]
  local function valid_buffers(state)
    local result = {}
    for bufnr in pairs(state.buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        local context = workflow.context(bufnr)
        if context and context.lsp_root == state.lsp_root then
          result[#result + 1] = bufnr
        end
      end
    end
    return result
  end

  ---@param state ArcadiaClangdState
  ---@param status ArcadiaLspServerStatus
  local function set_status(state, status)
    status.revision = state.revision
    api.status.set(state.lsp_root, SERVER, status)
  end

  ---@param state ArcadiaClangdState
  ---@param code string
  ---@param message string
  local function fail(state, code, message)
    state.running = false
    if state.temporary_path then
      vim.uv.fs_unlink(state.temporary_path)
      state.temporary_path = nil
    end
    set_status(state, { state = 'error', stage = 'compile_commands', message = message })
    api.notify.warn_once(state.lsp_root, SERVER, code, message)

    local database = vim.fs.joinpath(state.data_dir, 'compile_commands.json')
    if not api.cache.is_valid(database) and vim.fn.executable(state.ya_path) == 1 then
      api.clients.start(state.lsp_root, SERVER, valid_buffers(state))
    end
    state.waiting = {}
  end

  ---@param state ArcadiaClangdState
  ---@param result ArcadiaLspJobResult
  ---@param revision integer
  local function finish(state, result, revision)
    if revision ~= state.revision then
      if state.temporary_path then
        vim.uv.fs_unlink(state.temporary_path)
      end
      return
    end
    if result.timed_out then
      fail(state, 'ya_timeout', 'ya dump compile-commands timed out')
      return
    end
    if result.cancelled then
      state.running = false
      if state.temporary_path then
        vim.uv.fs_unlink(state.temporary_path)
        state.temporary_path = nil
      end
      set_status(state, { state = 'idle', stage = 'compile_commands' })
      return
    end
    if result.code ~= 0 then
      local detail = (result.stderr or ''):gsub('%s+$', '')
      local message = 'ya dump compile-commands failed'
      if detail ~= '' then
        message = message .. ': ' .. detail
      end
      fail(state, 'ya_failed', message)
      return
    end

    local database = vim.fs.joinpath(state.data_dir, 'compile_commands.json')
    local changed, install_error = api.cache.install(state.temporary_path, database)
    state.temporary_path = nil
    if changed == nil then
      fail(state, 'invalid_compile_commands', install_error)
      return
    end

    state.running = false
    configure_database(state)
    local buffers = valid_buffers(state)
    local running_clients = api.clients.get(state.lsp_root, SERVER)
    if changed and #running_clients > 0 then
      api.clients.restart(state.lsp_root, SERVER, buffers)
    else
      api.clients.start(state.lsp_root, SERVER, buffers)
    end
    state.waiting = {}
    set_status(state, { state = 'ready', stage = 'compile_commands' })
  end

  ---@param context table
  ---@param force boolean
  ---@return boolean?, string?
  local function generate(context, force)
    local state = state_for(context)
    local key = state.lsp_root .. '\0' .. SERVER
    if state.running and not force then
      api.jobs.add_interest(key, context.bufnr)
      return true
    end
    if state.running then
      api.jobs.cancel(key, 'refresh requested')
    end

    state.revision = state.revision + 1
    state.attempted = true
    state.running = true
    local revision = state.revision
    local directory_ok, directory_error = api.paths.ensure(state.data_dir)
    if not directory_ok then
      fail(state, 'data_directory', directory_error)
      return nil, directory_error
    end
    state.temporary_path =
      vim.fs.joinpath(state.data_dir, ('compile_commands.json.tmp.%d'):format(revision))
    set_status(state, {
      state = 'waiting',
      stage = 'compile_commands',
      message = 'Generating compile commands',
    })

    if vim.fn.executable(state.ya_path) ~= 1 then
      local message = ('Arcadia ya is not executable: %s'):format(state.ya_path)
      fail(state, 'missing_ya', message)
      return nil, message
    end

    local _, start_error = api.jobs.start(key, {
      cmd = {
        state.ya_path,
        'dump',
        'compile-commands',
        '--output-file=' .. state.temporary_path,
      },
      cwd = state.lsp_root,
      bufnr = context.bufnr,
      on_exit = function(result)
        finish(state, result, revision)
      end,
    })
    if start_error then
      fail(
        state,
        'ya_start_failed',
        ('cannot start ya dump compile-commands: %s'):format(start_error)
      )
      return nil, start_error
    end
    return true
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return boolean?, string?
  function workflow.activate(bufnr, context)
    context = context or workflow.context(bufnr)
    if not context then
      return nil, 'buffer is not in an Arcadia ya.make root'
    end
    local state = state_for(context)
    state.buffers[bufnr] = true
    api.status.associate(bufnr, context.arcadia_root, context.lsp_root, SERVER)
    api.clients.detach_wrong_root(bufnr, SERVER, context.lsp_root)
    configure_command(state)

    local database = vim.fs.joinpath(state.data_dir, 'compile_commands.json')
    if api.cache.is_valid(database) then
      configure_database(state)
      if vim.fn.executable(state.ya_path) == 1 then
        api.clients.start(state.lsp_root, SERVER, { bufnr })
      end
      if not state.attempted then
        return generate(context, false)
      elseif state.running then
        api.jobs.add_interest(state.lsp_root .. '\0' .. SERVER, bufnr)
      end
      return true
    end

    state.waiting[bufnr] = true
    if state.running then
      api.jobs.add_interest(state.lsp_root .. '\0' .. SERVER, bufnr)
      return true
    end
    if state.attempted then
      if vim.fn.executable(state.ya_path) == 1 then
        api.clients.start(state.lsp_root, SERVER, { bufnr })
      end
      return true
    end
    return generate(context, false)
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.refresh(bufnr)
    local context = workflow.context(bufnr)
    if not context then
      return nil, 'current buffer is not in an Arcadia ya.make root'
    end
    local state = state_for(context)
    state.buffers[bufnr] = true
    api.status.associate(bufnr, context.arcadia_root, context.lsp_root, SERVER)
    configure_command(state)
    return generate(context, true)
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.restart(bufnr)
    local context = workflow.context(bufnr)
    if not context then
      return nil, 'current buffer is not in an Arcadia ya.make root'
    end
    local state = state_for(context)
    state.buffers[bufnr] = true
    configure_command(state)
    local database = vim.fs.joinpath(state.data_dir, 'compile_commands.json')
    if api.cache.is_valid(database) then
      configure_database(state)
    end
    if vim.fn.executable(state.ya_path) ~= 1 then
      local message = ('Arcadia ya is not executable: %s'):format(state.ya_path)
      api.notify.warn_once(state.lsp_root, SERVER, 'missing_ya', message)
      return nil, message
    end
    api.clients.restart(state.lsp_root, SERVER, valid_buffers(state))
    return true
  end

  ---@return table<string, ArcadiaClangdState>
  function workflow._states()
    return states
  end

  return workflow
end
