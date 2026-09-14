local M = {}

---@class ArcadiaLspJobResult
---@field code integer
---@field signal integer
---@field stdout? string
---@field stderr? string
---@field cancelled? boolean
---@field timed_out? boolean

---@class ArcadiaLspJobSpec
---@field cmd string[]
---@field cwd string
---@field bufnr integer
---@field timeout_ms? number
---@field on_exit fun(result: ArcadiaLspJobResult)

---@class ArcadiaLspJob
---@field key string
---@field process vim.SystemObj?
---@field interested table<integer, boolean>
---@field cancelled boolean
---@field timed_out boolean
---@field timer? uv.uv_timer_t
---@field on_exit fun(result: ArcadiaLspJobResult)

---@type table<string, ArcadiaLspJob>
local active = {}
local options = { cancel_on_buff_exit = true, timeout_ms = nil }
---@type fun(cmd: string[], opts: table, callback: fun(result: vim.SystemCompleted)) : vim.SystemObj
local system = vim.system
local augroup

---@param job ArcadiaLspJob
local function close_timer(job)
  if job.timer and not job.timer:is_closing() then
    job.timer:stop()
    job.timer:close()
  end
  job.timer = nil
end

---@param key string
---@param reason string
function M.cancel(key, reason)
  local job = active[key]
  if not job then
    return
  end
  active[key] = nil
  job.cancelled = true
  close_timer(job)
  if job.process then
    pcall(job.process.kill, job.process, 15)
  end
  require('arcadia-lspconfig.log').debug(
    ('cancelled job %s (%s)'):format(key, reason or 'cancelled')
  )
end

---@param bufnr integer
function M.drop_buffer(bufnr)
  for key, job in pairs(active) do
    job.interested[bufnr] = nil
    if options.cancel_on_buff_exit and not next(job.interested) then
      M.cancel(key, 'no interested buffers')
    end
  end
end

function M.cancel_all()
  local keys = vim.tbl_keys(active)
  for _, key in ipairs(keys) do
    M.cancel(key, 'Neovim exit')
  end
end

---@param opts table
function M.setup(opts)
  options = vim.deepcopy(opts)
  augroup = vim.api.nvim_create_augroup('ArcadiaLspJobs', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = augroup,
    callback = function(event)
      M.drop_buffer(event.buf)
      require('arcadia-lspconfig.status').dissociate(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = M.cancel_all,
  })
end

---@param key string
---@param bufnr integer
---@return boolean
function M.add_interest(key, bufnr)
  local job = active[key]
  if not job then
    return false
  end
  job.interested[bufnr] = true
  return true
end

---@param key string
---@return ArcadiaLspJob?
function M.get(key)
  return active[key]
end

---@param key string
---@param spec ArcadiaLspJobSpec
---@return ArcadiaLspJob?, string?
function M.start(key, spec)
  if active[key] then
    active[key].interested[spec.bufnr] = true
    return active[key]
  end

  local job = {
    key = key,
    interested = { [spec.bufnr] = true },
    cancelled = false,
    timed_out = false,
    on_exit = spec.on_exit,
  }
  active[key] = job

  local ok, process_or_error = pcall(
    system,
    spec.cmd,
    { cwd = spec.cwd, text = true },
    function(result)
      vim.schedule(function()
        close_timer(job)
        if active[key] == job then
          active[key] = nil
        end
        result.cancelled = job.cancelled
        result.timed_out = job.timed_out
        job.on_exit(result)
      end)
    end
  )
  if not ok then
    active[key] = nil
    return nil, tostring(process_or_error)
  end
  job.process = process_or_error

  local timeout = spec.timeout_ms
  if timeout == nil then
    timeout = options.timeout_ms
  end
  if timeout then
    job.timer = vim.uv.new_timer()
    job.timer:start(timeout, 0, function()
      job.timed_out = true
      job.cancelled = true
      if job.process then
        pcall(job.process.kill, job.process, 15)
      end
    end)
  end
  return job
end

function M._reset()
  M.cancel_all()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = nil
  options = { cancel_on_buff_exit = true, timeout_ms = nil }
  system = vim.system
end

---@param replacement fun(
---  cmd: string[],
---  opts: table,
---  callback: fun(result: vim.SystemCompleted)
---): vim.SystemObj
function M._set_system(replacement)
  system = replacement
end

return M
