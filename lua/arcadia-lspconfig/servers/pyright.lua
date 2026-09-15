---@param api table
---@param server? string
---@param display_name? string
---@return table
return function(api, server, display_name)
  local SERVER = server or 'pyright'
  local DISPLAY_NAME = display_name or 'Pyright'
  local CONFIG_STAGE = SERVER .. '_config'
  local codegen_enabled = not api.options or api.options.servers[SERVER].codegen ~= false
  ---@class ArcadiaPythonStageState
  ---@field state string
  ---@field message? string
  ---@class ArcadiaPythonState
  ---@field arcadia_root string
  ---@field lsp_root string
  ---@field data_dir string
  ---@field ya_path string
  ---@field buffers table<integer, boolean>
  ---@field attempted boolean
  ---@field stages table<string, ArcadiaPythonStageState>
  ---@field revision integer
  ---@field configuration_configured boolean
  ---@field client_error? string
  ---@field active_project_dir? string
  ---@type table<string, ArcadiaPythonState>
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
  ---@return ArcadiaPythonState
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
          configuration = { state = 'idle' },
          build = { state = 'idle' },
        },
        revision = 0,
        configuration_configured = false,
      }
      states[context.lsp_root] = state
    end
    return state
  end

  ---@param state ArcadiaPythonState
  ---@param status ArcadiaLspServerStatus
  local function publish(state, status)
    status.revision = state.revision
    api.status.set(state.lsp_root, SERVER, status)
  end

  ---@param state ArcadiaPythonState
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
  ---@param state ArcadiaPythonState
  ---@return string
  local function manifest_path(state)
    return vim.fs.joinpath(state.data_dir, 'config.json')
  end
  ---@param state ArcadiaPythonState
  ---@return string
  local function project_config_path(state)
    return vim.fs.joinpath(state.lsp_root, 'pyrightconfig.json')
  end
  ---@param state ArcadiaPythonState
  ---@return boolean, string?
  local function server_available(state)
    local resolved = api.config.resolve(state.lsp_root, SERVER)
    if type(resolved.cmd) ~= 'table' or type(resolved.cmd[1]) ~= 'string' then
      return true
    end
    if vim.fn.executable(resolved.cmd[1]) == 1 then
      return true
    end
    return false, ('%s executable is not available: %s'):format(DISPLAY_NAME, resolved.cmd[1])
  end

  ---@param state ArcadiaPythonState
  ---@param extra_paths string[]
  local function configure(state, extra_paths)
    local settings_key = SERVER == 'basedpyright' and 'basedpyright' or 'python'
    api.config.extend(state.lsp_root, SERVER, {
      settings = { [settings_key] = { analysis = { extraPaths = extra_paths } } },
    })
    state.configuration_configured = true
  end

  ---@param state ArcadiaPythonState
  ---@param stage string
  ---@return boolean
  local function stage_is_running(state, stage)
    return state.stages[stage].state == 'waiting'
  end

  ---@param state ArcadiaPythonState
  ---@return boolean
  local function any_stage_running(state)
    return stage_is_running(state, 'configuration') or stage_is_running(state, 'build')
  end

  ---@param state ArcadiaPythonState
  local function update_status(state)
    local configuration = state.stages.configuration
    local build = state.stages.build
    if configuration.state == 'waiting' and build.state == 'waiting' then
      publish(state, {
        state = 'waiting',
        stage = 'prepare',
        message = ('Generating %s import paths and building Python results'):format(DISPLAY_NAME),
      })
    elseif configuration.state == 'waiting' then
      publish(state, { state = 'waiting', stage = CONFIG_STAGE, message = configuration.message })
    elseif build.state == 'waiting' then
      publish(state, { state = 'waiting', stage = 'build', message = build.message })
    elseif configuration.state == 'error' then
      publish(state, { state = 'error', stage = CONFIG_STAGE, message = configuration.message })
    elseif build.state == 'error' then
      publish(state, { state = 'error', stage = 'build', message = build.message })
    elseif state.client_error then
      publish(state, { state = 'warning', stage = CONFIG_STAGE, message = state.client_error })
    elseif configuration.state == 'ready' and build.state == 'ready' then
      publish(state, { state = 'ready', stage = 'prepare' })
    else
      publish(state, { state = 'idle', stage = 'prepare' })
    end
  end

  ---@param state ArcadiaPythonState
  ---@param restart boolean
  ---@return boolean, string?
  local function start_client(state, restart)
    local available, message = server_available(state)
    if not available then
      state.client_error = message
      api.notify.warn_once(state.lsp_root, SERVER, 'missing_' .. SERVER, message)
      publish(state, { state = 'warning', stage = CONFIG_STAGE, message = message })
      return false, message
    end
    state.client_error = nil
    if restart then
      api.clients.restart(state.lsp_root, SERVER, valid_buffers(state))
    else
      api.clients.start(state.lsp_root, SERVER, valid_buffers(state))
    end
    return true
  end

  ---@param state ArcadiaPythonState
  ---@param stage string
  ---@param code string
  ---@param message string
  local function fail_stage(state, stage, code, message)
    state.stages[stage] = { state = 'error', message = message }
    api.notify.warn_once(state.lsp_root, SERVER, code, message)
    update_status(state)
  end

  ---@param path string?
  local function remove_project(path)
    if path then
      vim.fn.delete(path, 'rf')
    end
  end

  ---@param state ArcadiaPythonState
  ---@param result ArcadiaLspJobResult
  ---@param revision integer
  ---@param project_dir string
  local function finish_configuration(state, result, revision, project_dir)
    if revision ~= state.revision then
      remove_project(project_dir)
      return
    end
    if result.timed_out then
      remove_project(project_dir)
      fail_stage(state, 'configuration', 'ya_ide_timeout', 'ya ide vscode timed out')
      return
    end
    if result.cancelled then
      remove_project(project_dir)
      state.stages.configuration = { state = 'idle' }
      update_status(state)
      return
    end
    if result.code ~= 0 then
      local detail = (result.stderr or ''):gsub('%s+$', '')
      local message = 'ya ide vscode failed'
      if detail ~= '' then
        message = message .. ': ' .. detail
      end
      remove_project(project_dir)
      fail_stage(state, 'configuration', 'ya_ide_failed', message)
      return
    end

    local workspace = vim.fs.joinpath(project_dir, 'arcadia-pyright.code-workspace')
    local generated, parse_error = api.cache.from_workspace(workspace, project_dir)
    if not generated then
      remove_project(project_dir)
      fail_stage(state, 'configuration', 'invalid_pyright_config', parse_error)
      return
    end
    local installed, install_error = api.cache.install(manifest_path(state), generated, revision)
    if not installed then
      remove_project(project_dir)
      fail_stage(state, 'configuration', 'pyright_cache_install', install_error)
      return
    end

    local previous = state.active_project_dir
    state.active_project_dir = project_dir
    configure(state, generated.extra_paths)
    local started = start_client(state, true)
    if started and previous and previous ~= project_dir then
      remove_project(previous)
    end
    state.stages.configuration = { state = 'ready' }
    update_status(state)
  end

  ---@param state ArcadiaPythonState
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
    if state.configuration_configured then
      start_client(state, true)
    end
    update_status(state)
  end

  ---@param state ArcadiaPythonState
  ---@param stage string
  ---@return string
  local function job_key(state, stage)
    return state.lsp_root .. '\0' .. SERVER .. '\0' .. stage
  end

  ---@param state ArcadiaPythonState
  ---@param bufnr integer
  local function add_job_interest(state, bufnr)
    for _, stage in ipairs { 'configuration', 'build' } do
      if stage_is_running(state, stage) then
        api.jobs.add_interest(job_key(state, stage), bufnr)
      end
    end
  end

  ---@param state ArcadiaPythonState
  local function cancel_jobs(state)
    for _, stage in ipairs { 'configuration', 'build' } do
      if stage_is_running(state, stage) then
        api.jobs.cancel(job_key(state, stage), 'refresh requested')
      end
    end
  end

  ---@param state ArcadiaPythonState
  ---@param bufnr integer
  ---@param revision integer
  ---@param project_dir string
  ---@return boolean?, string?
  local function start_configuration(state, bufnr, revision, project_dir)
    local key = job_key(state, 'configuration')
    local job, start_error = api.jobs.start(key, {
      cmd = {
        state.ya_path,
        'ide',
        'vscode',
        '--py3',
        '--no-pyright-config',
        '-W=arcadia-pyright',
        '-P=' .. project_dir,
      },
      cwd = state.lsp_root,
      bufnr = bufnr,
      on_exit = function(result)
        finish_configuration(state, result, revision, project_dir)
      end,
    })
    if start_error then
      remove_project(project_dir)
      local message = ('cannot start ya ide vscode: %s'):format(start_error)
      fail_stage(state, 'configuration', 'ya_ide_start_failed', message)
      return nil, start_error
    end
    for _, interested_bufnr in ipairs(valid_buffers(state)) do
      api.jobs.add_interest(key, interested_bufnr)
    end
    return job and true or nil
  end

  ---@param state ArcadiaPythonState
  ---@param bufnr integer
  ---@param revision integer
  ---@return boolean?, string?
  local function start_build(state, bufnr, revision)
    local key = job_key(state, 'build')
    local job, start_error = api.jobs.start(key, {
      cmd = { state.ya_path, 'make', '--add-result=.py', '--replace-result', '-R' },
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
        configuration = { state = 'idle' },
        build = { state = 'idle' },
      }
      fail_stage(state, 'configuration', 'data_directory', directory_error)
      return nil, directory_error
    end
    if vim.fn.executable(state.ya_path) ~= 1 then
      local message = ('Arcadia ya is not executable: %s'):format(state.ya_path)
      state.stages = {
        configuration = { state = 'idle' },
        build = { state = 'idle' },
      }
      fail_stage(state, 'configuration', 'missing_ya', message)
      return nil, message
    end

    local project_dir = vim.fs.joinpath(
      state.data_dir,
      ('generation.%d.%s'):format(revision, tostring(vim.uv.hrtime()))
    )
    state.stages = {
      configuration = {
        state = 'waiting',
        message = ('Generating %s import paths'):format(DISPLAY_NAME),
      },
      build = codegen_enabled and { state = 'waiting', message = 'Building Python results' }
        or { state = 'ready' },
    }
    update_status(state)

    local configuration_started
    local configuration_error
    local project_ok, project_error = api.paths.ensure(project_dir)
    if project_ok then
      configuration_started, configuration_error =
        start_configuration(state, context.bufnr, revision, project_dir)
    else
      configuration_error = project_error
      fail_stage(state, 'configuration', 'data_directory', project_error)
    end
    local build_started, build_error
    if codegen_enabled then
      build_started, build_error = start_build(state, context.bufnr, revision)
    end
    if configuration_started or build_started then
      return true
    end
    return nil, configuration_error or build_error
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

    if vim.uv.fs_stat(project_config_path(state)) then
      state.attempted = true
      local started = start_client(state, false)
      if started then
        publish(state, { state = 'ready', stage = CONFIG_STAGE })
      end
      return true
    end

    local cached = api.cache.read(manifest_path(state))
    if cached then
      state.active_project_dir = cached.project_dir
      configure(state, cached.extra_paths)
      start_client(state, false)
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
    if vim.uv.fs_stat(project_config_path(state)) then
      local started, message = start_client(state, true)
      if started then
        publish(state, { state = 'ready', stage = CONFIG_STAGE })
        return true
      end
      return nil, message
    end
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
    if not vim.uv.fs_stat(project_config_path(state)) then
      local cached, cache_error = api.cache.read(manifest_path(state))
      if not cached then
        return nil,
          ('no valid %s configuration is available: %s'):format(
            DISPLAY_NAME,
            cache_error or manifest_path(state)
          )
      end
      state.active_project_dir = cached.project_dir
      configure(state, cached.extra_paths)
    end
    local started, message = start_client(state, true)
    if not started then
      return nil, message
    end
    return true
  end

  ---@param context table
  ---@return ArcadiaLspHealthEntry[]
  function workflow.health(context)
    local entries = {}
    local state = state_for(context)
    if vim.fn.executable(state.ya_path) == 1 then
      entries[#entries + 1] = {
        level = 'ok',
        message = ('Arcadia ya is executable: %s'):format(state.ya_path),
      }
    else
      entries[#entries + 1] = {
        level = 'error',
        message = ('Arcadia ya is not executable: %s'):format(state.ya_path),
      }
    end
    local available, executable_error = server_available(state)
    entries[#entries + 1] = {
      level = available and 'ok' or 'error',
      message = available and (DISPLAY_NAME .. ' command is available') or executable_error,
    }
    entries[#entries + 1] = {
      level = 'info',
      message = ('%s data directory: %s'):format(SERVER, state.data_dir),
    }
    local project_config = project_config_path(state)
    if vim.uv.fs_stat(project_config) then
      entries[#entries + 1] = {
        level = 'ok',
        message = ('Project %s configuration: %s'):format(DISPLAY_NAME, project_config),
      }
    else
      local manifest = manifest_path(state)
      local cached, cache_error = api.cache.read(manifest)
      if cached then
        entries[#entries + 1] = {
          level = 'ok',
          message = ('Valid cached %s configuration: %s'):format(DISPLAY_NAME, manifest),
        }
      elseif vim.uv.fs_stat(manifest) then
        entries[#entries + 1] = {
          level = 'error',
          message = ('Invalid cached %s configuration: %s'):format(DISPLAY_NAME, cache_error),
        }
      else
        entries[#entries + 1] = {
          level = 'info',
          message = ('No cached %s configuration exists yet'):format(DISPLAY_NAME),
        }
      end
    end
    entries[#entries + 1] = {
      level = 'info',
      message = ('%s preparation revision %d%s'):format(
        DISPLAY_NAME,
        state.revision,
        any_stage_running(state) and ' is running' or ''
      ),
    }
    return entries
  end

  ---@return table<string, ArcadiaPythonState>
  function workflow._states()
    return states
  end

  return workflow
end
