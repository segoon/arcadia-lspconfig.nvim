local SERVER = 'clangd'

---@param api table
---@return table
return function(api)
  ---@class ArcadiaClangdStageState
  ---@field state string
  ---@field message? string

  ---@class ArcadiaClangdState
  ---@field arcadia_root string
  ---@field lsp_root string
  ---@field data_dir string
  ---@field ya_path string
  ---@field buffers table<integer, boolean>
  ---@field attempted boolean
  ---@field stages table<string, ArcadiaClangdStageState>
  ---@field revision integer
  ---@field command_configured boolean
  ---@field database_configured boolean

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
        attempted = false,
        stages = {
          compile_commands = { state = 'idle' },
          build = { state = 'idle' },
        },
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
  local function publish_status(state, status)
    status.revision = state.revision
    api.status.set(state.lsp_root, SERVER, status)
  end

  ---@param state ArcadiaClangdState
  ---@param stage string
  ---@return boolean
  local function stage_is_running(state, stage)
    return state.stages[stage].state == 'waiting'
  end

  ---@param state ArcadiaClangdState
  ---@return boolean
  local function any_stage_running(state)
    return stage_is_running(state, 'compile_commands') or stage_is_running(state, 'build')
  end

  ---@param state ArcadiaClangdState
  local function update_status(state)
    local dump = state.stages.compile_commands
    local build = state.stages.build
    if dump.state == 'waiting' and build.state == 'waiting' then
      publish_status(state, {
        state = 'waiting',
        stage = 'prepare',
        message = 'Generating compile commands and building C++ results',
      })
    elseif dump.state == 'waiting' then
      publish_status(
        state,
        { state = 'waiting', stage = 'compile_commands', message = dump.message }
      )
    elseif build.state == 'waiting' then
      publish_status(state, { state = 'waiting', stage = 'build', message = build.message })
    elseif dump.state == 'error' then
      publish_status(state, { state = 'error', stage = 'compile_commands', message = dump.message })
    elseif build.state == 'error' then
      publish_status(state, { state = 'error', stage = 'build', message = build.message })
    elseif dump.state == 'ready' and build.state == 'ready' then
      publish_status(state, { state = 'ready', stage = 'prepare' })
    else
      publish_status(state, { state = 'idle', stage = 'prepare' })
    end
  end

  ---@param state ArcadiaClangdState
  ---@param stage string
  ---@return string
  local function job_key(state, stage)
    return state.lsp_root .. '\0' .. SERVER .. '\0' .. stage
  end

  ---@param state ArcadiaClangdState
  ---@param bufnr integer
  local function add_job_interest(state, bufnr)
    for _, stage in ipairs { 'compile_commands', 'build' } do
      if stage_is_running(state, stage) then
        api.jobs.add_interest(job_key(state, stage), bufnr)
      end
    end
  end

  ---@param state ArcadiaClangdState
  local function cancel_jobs(state)
    for _, stage in ipairs { 'compile_commands', 'build' } do
      if stage_is_running(state, stage) then
        api.jobs.cancel(job_key(state, stage), 'refresh requested')
      end
    end
  end

  ---@param path string?
  local function remove_temporary(path)
    if path then
      vim.uv.fs_unlink(path)
    end
  end

  ---@param state ArcadiaClangdState
  ---@param stage string
  ---@param code string
  ---@param message string
  local function fail_stage(state, stage, code, message)
    state.stages[stage] = { state = 'error', message = message }
    api.notify.warn_once(state.lsp_root, SERVER, code, message)
    update_status(state)
  end

  ---@param state ArcadiaClangdState
  ---@return string
  local function database_path(state)
    return vim.fs.joinpath(state.data_dir, 'compile_commands.json')
  end

  ---@param state ArcadiaClangdState
  ---@return boolean
  local function reload_if_database(state)
    if not api.cache.is_valid(database_path(state)) then
      return false
    end
    configure_database(state)
    api.clients.restart(state.lsp_root, SERVER, valid_buffers(state))
    return true
  end

  ---@param state ArcadiaClangdState
  ---@param result ArcadiaLspJobResult
  ---@param revision integer
  local function finish_build(state, result, revision)
    if revision ~= state.revision then
      return
    end
    if result.timed_out then
      fail_stage(state, 'build', 'ya_make_timeout', 'ya make timed out')
      return
    end
    if result.cancelled then
      state.stages.build = { state = 'idle' }
      update_status(state)
      return
    end
    if result.code ~= 0 then
      local detail = (result.stderr or ''):gsub('%s+$', '')
      local message = 'ya make failed'
      if detail ~= '' then
        message = message .. ': ' .. detail
      end
      fail_stage(state, 'build', 'ya_make_failed', message)
      return
    end

    state.stages.build = { state = 'ready' }
    reload_if_database(state)
    update_status(state)
  end

  ---@param state ArcadiaClangdState
  ---@param bufnr integer
  ---@param revision integer
  ---@return boolean?, string?
  local function start_build(state, bufnr, revision)
    local key = job_key(state, 'build')
    local build_root = vim.fs.joinpath(state.data_dir, 'build_root')
    local job, start_error = api.jobs.start(key, {
      cmd = {
        state.ya_path,
        'make',
        '--add-result=.hpp',
        '--add-result=.cpp',
        '--replace-result',
        '-o=' .. build_root,
      },
      cwd = state.lsp_root,
      bufnr = bufnr,
      on_exit = function(result)
        finish_build(state, result, revision)
      end,
    })
    if start_error then
      local message = ('cannot start ya make: %s'):format(start_error)
      fail_stage(state, 'build', 'ya_make_start_failed', message)
      return nil, start_error
    end
    for _, interested_bufnr in ipairs(valid_buffers(state)) do
      api.jobs.add_interest(key, interested_bufnr)
    end
    return job and true or nil
  end

  ---@param state ArcadiaClangdState
  ---@param result ArcadiaLspJobResult
  ---@param revision integer
  ---@param temporary_path string
  local function finish_dump(state, result, revision, temporary_path)
    if revision ~= state.revision then
      remove_temporary(temporary_path)
      return
    end
    if result.timed_out then
      remove_temporary(temporary_path)
      fail_stage(state, 'compile_commands', 'ya_timeout', 'ya dump compile-commands timed out')
      return
    end
    if result.cancelled then
      remove_temporary(temporary_path)
      state.stages.compile_commands = { state = 'idle' }
      update_status(state)
      return
    end
    if result.code ~= 0 then
      local detail = (result.stderr or ''):gsub('%s+$', '')
      local message = 'ya dump compile-commands failed'
      if detail ~= '' then
        message = message .. ': ' .. detail
      end
      remove_temporary(temporary_path)
      fail_stage(state, 'compile_commands', 'ya_failed', message)
      return
    end

    local installed, install_error = api.cache.install(temporary_path, database_path(state))
    if installed == nil then
      fail_stage(state, 'compile_commands', 'invalid_compile_commands', install_error)
      return
    end

    state.stages.compile_commands = { state = 'ready' }
    reload_if_database(state)
    update_status(state)
  end

  ---@param state ArcadiaClangdState
  ---@param bufnr integer
  ---@param revision integer
  ---@param temporary_path string
  ---@return boolean?, string?
  local function start_dump(state, bufnr, revision, temporary_path)
    local key = job_key(state, 'compile_commands')
    local job, start_error = api.jobs.start(key, {
      cmd = {
        state.ya_path,
        'dump',
        'compile-commands',
        '--output-file=' .. temporary_path,
        '--cmd-build-root=' .. vim.fs.joinpath(state.data_dir, 'build_root'),
      },
      cwd = state.lsp_root,
      bufnr = bufnr,
      on_exit = function(result)
        finish_dump(state, result, revision, temporary_path)
      end,
    })
    if start_error then
      remove_temporary(temporary_path)
      local message = ('cannot start ya dump compile-commands: %s'):format(start_error)
      fail_stage(state, 'compile_commands', 'ya_start_failed', message)
      return nil, start_error
    end
    for _, interested_bufnr in ipairs(valid_buffers(state)) do
      api.jobs.add_interest(key, interested_bufnr)
    end
    return job and true or nil
  end

  ---@param context table
  ---@param force boolean
  ---@return boolean?, string?
  local function generate(context, force)
    local state = state_for(context)
    if any_stage_running(state) and not force then
      add_job_interest(state, context.bufnr)
      return true
    end
    if any_stage_running(state) then
      cancel_jobs(state)
    end

    state.revision = state.revision + 1
    state.attempted = true
    local revision = state.revision
    local directory_ok, directory_error = api.paths.ensure(state.data_dir)
    if not directory_ok then
      state.stages = {
        compile_commands = { state = 'idle' },
        build = { state = 'idle' },
      }
      fail_stage(state, 'compile_commands', 'data_directory', directory_error)
      return nil, directory_error
    end
    if vim.fn.executable(state.ya_path) ~= 1 then
      local message = ('Arcadia ya is not executable: %s'):format(state.ya_path)
      state.stages = {
        compile_commands = { state = 'idle' },
        build = { state = 'idle' },
      }
      fail_stage(state, 'compile_commands', 'missing_ya', message)
      return nil, message
    end

    state.stages = {
      compile_commands = { state = 'waiting', message = 'Generating compile commands' },
      build = { state = 'waiting', message = 'Building C++ results' },
    }
    update_status(state)
    local temporary_path =
      vim.fs.joinpath(state.data_dir, ('compile_commands.json.tmp.%d'):format(revision))
    local dump_started, dump_error = start_dump(state, context.bufnr, revision, temporary_path)
    local build_started, build_error = start_build(state, context.bufnr, revision)
    if dump_started or build_started then
      return true
    end
    return nil, dump_error or build_error
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

    if api.cache.is_valid(database_path(state)) then
      configure_database(state)
      if vim.fn.executable(state.ya_path) == 1 then
        api.clients.start(state.lsp_root, SERVER, { bufnr })
      end
    end

    if not state.attempted then
      return generate(context, false)
    elseif any_stage_running(state) then
      add_job_interest(state, bufnr)
    end
    return true
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
    local database = database_path(state)
    if not api.cache.is_valid(database) then
      return nil, ('no valid compilation database is available: %s'):format(database)
    end
    configure_database(state)
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
