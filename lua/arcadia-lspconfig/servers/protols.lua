local SERVER = 'protols'

---@param api table
---@return ArcadiaLspWorkflow
return function(api)
  ---@class ArcadiaProtolsClientState
  ---@field arcadia_root string
  ---@field lsp_root string
  ---@field data_dir string
  ---@field ya_path string
  ---@field buffers table<integer, boolean>
  ---@field record? ArcadiaProtolsRecord

  ---@class ArcadiaProtolsTargetState
  ---@field arcadia_root string
  ---@field target_root string
  ---@field data_dir string
  ---@field ya_path string
  ---@field buffers table<integer, boolean>
  ---@field attempted boolean
  ---@field running boolean
  ---@field revision integer

  ---@type table<string, ArcadiaProtolsClientState>
  local clients = {}
  ---@type table<string, ArcadiaProtolsTargetState>
  local targets = {}
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
      path = vim.fs.normalize(name),
      arcadia_root = roots.arcadia_root,
      lsp_root = roots.lsp_root,
      data_dir = api.paths.data(roots.arcadia_root, SERVER),
    }
  end

  ---@param context table
  ---@return ArcadiaProtolsClientState
  local function client_for(context)
    local state = clients[context.lsp_root]
    if not state then
      state = {
        arcadia_root = context.arcadia_root,
        lsp_root = context.lsp_root,
        data_dir = context.data_dir,
        ya_path = vim.fs.joinpath(context.arcadia_root, 'ya'),
        buffers = {},
      }
      clients[context.lsp_root] = state
    end
    return state
  end

  ---@param context table
  ---@param target_root string
  ---@return ArcadiaProtolsTargetState
  local function target_for(context, target_root)
    local state = targets[target_root]
    if not state then
      state = {
        arcadia_root = context.arcadia_root,
        target_root = target_root,
        data_dir = context.data_dir,
        ya_path = vim.fs.joinpath(context.arcadia_root, 'ya'),
        buffers = {},
        attempted = false,
        running = false,
        revision = 0,
      }
      targets[target_root] = state
    end
    return state
  end

  ---@param state ArcadiaProtolsClientState
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

  ---@param state ArcadiaProtolsClientState
  ---@return boolean, string?
  local function server_available(state)
    local resolved = api.config.resolve(state.lsp_root, SERVER)
    if type(resolved.cmd) ~= 'table' or type(resolved.cmd[1]) ~= 'string' then
      return true
    end
    if vim.fn.executable(resolved.cmd[1]) == 1 then
      return true
    end
    return false, ('Protols executable is not available: %s'):format(resolved.cmd[1])
  end

  ---@param state ArcadiaProtolsClientState
  ---@param record ArcadiaProtolsRecord
  ---@return boolean?, string?
  local function configure(state, record)
    local bin_dir, wrapper_error = api.cache.ensure_wrappers(state.data_dir)
    if not bin_dir then
      return nil, wrapper_error
    end
    api.config.extend(state.lsp_root, SERVER, {
      init_options = { include_paths = record.include_paths },
      cmd_env = {
        ARCADIA_LSPCONFIG_ROOT = state.arcadia_root,
        ARCADIA_LSPCONFIG_YA = state.ya_path,
        PATH = bin_dir .. ':' .. (vim.env.PATH or ''),
      },
    })
    state.record = record
    return true
  end

  ---@param state ArcadiaProtolsClientState
  ---@param restart boolean
  ---@return boolean?, string?
  local function start_client(state, restart)
    local available, message = server_available(state)
    if not available then
      api.notify.warn_once(state.lsp_root, SERVER, 'missing_protols', message)
      return nil, message
    end
    if restart then
      api.clients.restart(state.lsp_root, SERVER, valid_buffers(state))
    else
      api.clients.start(state.lsp_root, SERVER, valid_buffers(state))
    end
    return true
  end

  ---@param target ArcadiaProtolsTargetState
  ---@param status ArcadiaLspServerStatus
  local function publish(target, status)
    status.revision = target.revision
    local roots = {}
    for bufnr in pairs(target.buffers) do
      local context = workflow.context(bufnr)
      if context then
        roots[context.lsp_root] = true
      end
    end
    if not next(roots) then
      roots[target.target_root] = true
    end
    for lsp_root in pairs(roots) do
      api.status.set(lsp_root, SERVER, status)
    end
  end

  ---@param target ArcadiaProtolsTargetState
  ---@param code string
  ---@param message string
  local function fail(target, code, message)
    target.running = false
    api.notify.warn_once(target.target_root, SERVER, code, message)
    publish(target, { state = 'error', stage = 'build_plan', message = message })
  end

  ---@param target ArcadiaProtolsTargetState
  ---@return string
  local function job_key(target)
    return target.target_root .. '\0' .. SERVER .. '\0build_plan'
  end

  ---@param target ArcadiaProtolsTargetState
  local function add_job_interest(target)
    for bufnr in pairs(target.buffers) do
      api.jobs.add_interest(job_key(target), bufnr)
    end
  end

  ---@param index ArcadiaProtolsIndex
  ---@param target ArcadiaProtolsTargetState
  local function apply_index(index, target)
    for bufnr in pairs(target.buffers) do
      local context = workflow.context(bufnr)
      if context then
        local state = client_for(context)
        state.buffers[bufnr] = true
        local record = api.cache.select(index, context.path, context.lsp_root)
        if record then
          local configured, configure_error = configure(state, record)
          if configured then
            start_client(state, true)
          else
            fail(target, 'wrapper_failed', configure_error)
            return
          end
        end
      end
    end
  end

  ---@param target ArcadiaProtolsTargetState
  ---@param result ArcadiaLspJobResult
  ---@param revision integer
  ---@param temporary_path string
  local function finish_dump(target, result, revision, temporary_path)
    if revision ~= target.revision then
      vim.uv.fs_unlink(temporary_path)
      return
    end
    target.running = false
    if result.timed_out then
      vim.uv.fs_unlink(temporary_path)
      fail(target, 'ya_dump_timeout', 'ya dump build-plan timed out')
      return
    end
    if result.cancelled then
      vim.uv.fs_unlink(temporary_path)
      publish(target, { state = 'idle', stage = 'build_plan' })
      return
    end
    if result.stdout_error then
      vim.uv.fs_unlink(temporary_path)
      fail(target, 'ya_dump_output', 'cannot cache ya dump build-plan: ' .. result.stdout_error)
      return
    end
    if result.code ~= 0 then
      local detail = (result.stderr or ''):gsub('%s+$', '')
      local message = 'ya dump build-plan failed'
      if detail ~= '' then
        message = message .. ': ' .. detail
      end
      vim.uv.fs_unlink(temporary_path)
      fail(target, 'ya_dump_failed', message)
      return
    end

    local generation = ('%d-%d'):format(os.time(), revision)
    local raw_name =
      vim.fs.joinpath('plans', vim.fn.sha256(target.target_root) .. '.' .. generation .. '.json')
    local record, parse_error = api.cache.from_plan(
      temporary_path,
      target.arcadia_root,
      target.target_root,
      raw_name,
      os.time()
    )
    if not record then
      vim.uv.fs_unlink(temporary_path)
      fail(target, 'invalid_build_plan', parse_error)
      return
    end
    local index, install_error =
      api.cache.install(target.data_dir, temporary_path, record, generation)
    if not index then
      vim.uv.fs_unlink(temporary_path)
      fail(target, 'cache_install_failed', install_error)
      return
    end
    apply_index(index, target)
    publish(target, { state = 'ready', stage = 'build_plan' })
  end

  ---@param context table
  ---@param target_root string
  ---@param force boolean
  ---@return boolean?, string?
  local function generate(context, target_root, force)
    local target = target_for(context, target_root)
    target.buffers[context.bufnr] = true
    if target.running and not force then
      add_job_interest(target)
      return true
    end
    if target.running then
      api.jobs.cancel(job_key(target), 'refresh requested')
    end
    target.revision = target.revision + 1
    target.attempted = true
    target.running = true
    local revision = target.revision

    local directory_ok, directory_error = api.paths.ensure(target.data_dir)
    if not directory_ok then
      fail(target, 'data_directory', directory_error)
      return nil, directory_error
    end
    if vim.fn.executable(target.ya_path) ~= 1 then
      local message = ('Arcadia ya is not executable: %s'):format(target.ya_path)
      fail(target, 'missing_ya', message)
      return nil, message
    end

    publish(target, {
      state = 'waiting',
      stage = 'build_plan',
      message = 'Discovering Proto import paths',
    })
    local temporary = vim.fs.joinpath(target.data_dir, ('build-plan.json.tmp.%d'):format(revision))
    local job, start_error = api.jobs.start(job_key(target), {
      cmd = { target.ya_path, 'dump', 'build-plan', '.', '--ignore-recurses' },
      cwd = target.target_root,
      bufnr = context.bufnr,
      stdout_path = temporary,
      on_exit = function(result)
        finish_dump(target, result, revision, temporary)
      end,
    })
    if start_error then
      vim.uv.fs_unlink(temporary)
      fail(target, 'ya_dump_start_failed', 'cannot start ya dump build-plan: ' .. start_error)
      return nil, start_error
    end
    add_job_interest(target)
    return job and true or nil
  end

  ---@param bufnr integer
  ---@param context? table
  ---@return boolean?, string?
  function workflow.activate(bufnr, context)
    context = context or workflow.context(bufnr)
    if not context then
      return nil, 'buffer is not in an Arcadia ya.make root'
    end
    local state = client_for(context)
    state.buffers[bufnr] = true
    api.status.associate(bufnr, context.arcadia_root, context.lsp_root, SERVER)
    api.clients.detach_wrong_root(bufnr, SERVER, context.lsp_root)

    local index = api.cache.read(context.data_dir)
    local record = index and api.cache.select(index, context.path, context.lsp_root) or nil
    local target_root = record and record.target_root or context.lsp_root
    local target = target_for(context, target_root)
    target.buffers[bufnr] = true
    if record then
      local configured, configure_error = configure(state, record)
      if not configured then
        fail(target, 'wrapper_failed', configure_error)
        return nil, configure_error
      end
      start_client(state, false)
    end
    if not target.attempted then
      return generate(context, target_root, false)
    elseif target.running then
      add_job_interest(target)
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
    local state = client_for(context)
    state.buffers[bufnr] = true
    api.status.associate(bufnr, context.arcadia_root, context.lsp_root, SERVER)
    local target_root = state.record and state.record.target_root or context.lsp_root
    return generate(context, target_root, true)
  end

  ---@param bufnr integer
  ---@return boolean?, string?
  function workflow.restart(bufnr)
    local context = workflow.context(bufnr)
    if not context then
      return nil, 'current buffer is not in an Arcadia ya.make root'
    end
    local state = client_for(context)
    state.buffers[bufnr] = true
    local index, cache_error = api.cache.read(context.data_dir)
    local record = index and api.cache.select(index, context.path, context.lsp_root) or nil
    if not record then
      return nil, cache_error or 'no cached Protols build plan covers the current file'
    end
    local configured, configure_error = configure(state, record)
    if not configured then
      return nil, configure_error
    end
    return start_client(state, true)
  end

  ---@param context table
  ---@return ArcadiaLspHealthEntry[]
  function workflow.health(context)
    local entries = {}
    local state = client_for(context)
    if vim.fn.executable(state.ya_path) == 1 then
      entries[#entries + 1] =
        { level = 'ok', message = 'Arcadia ya is executable: ' .. state.ya_path }
    else
      entries[#entries + 1] =
        { level = 'error', message = 'Arcadia ya is not executable: ' .. state.ya_path }
    end
    local index, cache_error = api.cache.read(context.data_dir)
    local record = index and api.cache.select(index, context.path, context.lsp_root) or nil
    if record then
      entries[#entries + 1] = {
        level = 'ok',
        message = ('Cached Protols build plan from %s covers this file'):format(record.target_root),
      }
    elseif vim.uv.fs_stat(vim.fs.joinpath(context.data_dir, 'index.json')) then
      entries[#entries + 1] = {
        level = 'error',
        message = 'Invalid Protols cache: ' .. (cache_error or 'file is not covered'),
      }
    else
      entries[#entries + 1] =
        { level = 'info', message = 'No cached Protols build plan exists yet' }
    end
    entries[#entries + 1] =
      { level = 'info', message = 'Protols data directory: ' .. context.data_dir }
    return entries
  end

  function workflow._states()
    return { clients = clients, targets = targets }
  end

  return workflow
end
