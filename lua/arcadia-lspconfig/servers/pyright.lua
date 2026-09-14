local SERVER = 'pyright'
local STAGE = 'pyright_config'

---@param api table
---@return table
return function(api)
  ---@class ArcadiaPyrightState
  ---@field arcadia_root string
  ---@field lsp_root string
  ---@field data_dir string
  ---@field ya_path string
  ---@field buffers table<integer, boolean>
  ---@field attempted boolean
  ---@field running boolean
  ---@field revision integer
  ---@field active_project_dir? string

  ---@type table<string, ArcadiaPyrightState>
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
  ---@return ArcadiaPyrightState
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
        running = false,
        revision = 0,
      }
      states[context.lsp_root] = state
    end
    return state
  end

  ---@param state ArcadiaPyrightState
  ---@param status ArcadiaLspServerStatus
  local function publish(state, status)
    status.revision = state.revision
    api.status.set(state.lsp_root, SERVER, status)
  end

  ---@param state ArcadiaPyrightState
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

  ---@param state ArcadiaPyrightState
  ---@return string
  local function manifest_path(state)
    return vim.fs.joinpath(state.data_dir, 'config.json')
  end

  ---@param state ArcadiaPyrightState
  ---@return string
  local function project_config_path(state)
    return vim.fs.joinpath(state.lsp_root, 'pyrightconfig.json')
  end

  ---@param state ArcadiaPyrightState
  ---@return boolean, string?
  local function pyright_available(state)
    local resolved = api.config.resolve(state.lsp_root, SERVER)
    if type(resolved.cmd) ~= 'table' or type(resolved.cmd[1]) ~= 'string' then
      return true
    end
    if vim.fn.executable(resolved.cmd[1]) == 1 then
      return true
    end
    return false, ('Pyright executable is not available: %s'):format(resolved.cmd[1])
  end

  ---@param state ArcadiaPyrightState
  ---@param extra_paths string[]
  local function configure(state, extra_paths)
    api.config.extend(state.lsp_root, SERVER, {
      settings = { python = { analysis = { extraPaths = extra_paths } } },
    })
  end

  ---@param state ArcadiaPyrightState
  ---@param restart boolean
  ---@return boolean, string?
  local function start_client(state, restart)
    local available, message = pyright_available(state)
    if not available then
      api.notify.warn_once(state.lsp_root, SERVER, 'missing_pyright', message)
      publish(state, { state = 'warning', stage = STAGE, message = message })
      return false, message
    end
    if restart then
      api.clients.restart(state.lsp_root, SERVER, valid_buffers(state))
    else
      api.clients.start(state.lsp_root, SERVER, valid_buffers(state))
    end
    return true
  end

  ---@param state ArcadiaPyrightState
  ---@param code string
  ---@param message string
  local function fail(state, code, message)
    state.running = false
    publish(state, { state = 'error', stage = STAGE, message = message })
    api.notify.warn_once(state.lsp_root, SERVER, code, message)
  end

  ---@param path string?
  local function remove_project(path)
    if path then
      vim.fn.delete(path, 'rf')
    end
  end

  ---@param state ArcadiaPyrightState
  ---@param result ArcadiaLspJobResult
  ---@param revision integer
  ---@param project_dir string
  local function finish(state, result, revision, project_dir)
    if revision ~= state.revision then
      remove_project(project_dir)
      return
    end
    state.running = false
    if result.timed_out then
      remove_project(project_dir)
      fail(state, 'ya_ide_timeout', 'ya ide vscode timed out')
      return
    end
    if result.cancelled then
      remove_project(project_dir)
      publish(state, { state = 'idle', stage = STAGE })
      return
    end
    if result.code ~= 0 then
      local detail = (result.stderr or ''):gsub('%s+$', '')
      local message = 'ya ide vscode failed'
      if detail ~= '' then
        message = message .. ': ' .. detail
      end
      remove_project(project_dir)
      fail(state, 'ya_ide_failed', message)
      return
    end

    local workspace = vim.fs.joinpath(project_dir, 'arcadia-pyright.code-workspace')
    local generated, parse_error = api.pyright_cache.from_workspace(workspace, project_dir)
    if not generated then
      remove_project(project_dir)
      fail(state, 'invalid_pyright_config', parse_error)
      return
    end
    local installed, install_error =
      api.pyright_cache.install(manifest_path(state), generated, revision)
    if not installed then
      remove_project(project_dir)
      fail(state, 'pyright_cache_install', install_error)
      return
    end

    local previous = state.active_project_dir
    state.active_project_dir = project_dir
    configure(state, generated.extra_paths)
    local started = start_client(state, true)
    if started and previous and previous ~= project_dir then
      remove_project(previous)
    end
    if started then
      publish(state, { state = 'ready', stage = STAGE })
    end
  end

  ---@param state ArcadiaPyrightState
  ---@return string
  local function job_key(state)
    return state.lsp_root .. '\0' .. SERVER
  end

  ---@param context table
  ---@param force boolean
  ---@return boolean?, string?
  local function generate(context, force)
    local state = state_for(context)
    if state.running and not force then
      api.jobs.add_interest(job_key(state), context.bufnr)
      return true
    end
    if state.running then
      api.jobs.cancel(job_key(state), 'refresh requested')
    end
    state.revision = state.revision + 1
    state.attempted = true
    local revision = state.revision

    local directory_ok, directory_error = api.paths.ensure(state.data_dir)
    if not directory_ok then
      fail(state, 'data_directory', directory_error)
      return nil, directory_error
    end
    if vim.fn.executable(state.ya_path) ~= 1 then
      local message = ('Arcadia ya is not executable: %s'):format(state.ya_path)
      fail(state, 'missing_ya', message)
      return nil, message
    end

    local project_dir = vim.fs.joinpath(
      state.data_dir,
      ('generation.%d.%s'):format(revision, tostring(vim.uv.hrtime()))
    )
    local project_ok, project_error = api.paths.ensure(project_dir)
    if not project_ok then
      fail(state, 'data_directory', project_error)
      return nil, project_error
    end
    state.running = true
    publish(state, {
      state = 'waiting',
      stage = STAGE,
      message = 'Generating Pyright import paths',
    })
    local _, start_error = api.jobs.start(job_key(state), {
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
      bufnr = context.bufnr,
      on_exit = function(result)
        finish(state, result, revision, project_dir)
      end,
    })
    if start_error then
      remove_project(project_dir)
      fail(state, 'ya_ide_start_failed', ('cannot start ya ide vscode: %s'):format(start_error))
      return nil, start_error
    end
    for _, bufnr in ipairs(valid_buffers(state)) do
      api.jobs.add_interest(job_key(state), bufnr)
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

    if vim.uv.fs_stat(project_config_path(state)) then
      state.attempted = true
      local started = start_client(state, false)
      if started then
        publish(state, { state = 'ready', stage = STAGE })
      end
      return true
    end

    local cached = api.pyright_cache.read(manifest_path(state))
    if cached then
      state.active_project_dir = cached.project_dir
      configure(state, cached.extra_paths)
      start_client(state, false)
    end
    if not state.attempted then
      return generate(context, false)
    elseif state.running then
      api.jobs.add_interest(job_key(state), bufnr)
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
        publish(state, { state = 'ready', stage = STAGE })
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
      local cached, cache_error = api.pyright_cache.read(manifest_path(state))
      if not cached then
        return nil,
          ('no valid Pyright configuration is available: %s'):format(
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

  ---@return table<string, ArcadiaPyrightState>
  function workflow._states()
    return states
  end

  return workflow
end
