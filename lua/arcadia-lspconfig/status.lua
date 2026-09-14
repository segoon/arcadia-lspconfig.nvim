local M = {}

---@class ArcadiaLspServerStatus
---@field state string
---@field stage? string
---@field message? string
---@field revision? integer

---@class ArcadiaLspStatus
---@field arcadia_root string
---@field lsp_root string
---@field servers table<string, ArcadiaLspServerStatus>

---@type table<string, table<string, ArcadiaLspServerStatus>>
local states = {}
---@type table<integer, { arcadia_root: string, lsp_root: string, servers: table<string, boolean> }>
local buffers = {}

local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function emit_change()
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, 'User', {
      pattern = 'ArcadiaLspStatusChanged',
      modeline = false,
    })
    pcall(vim.cmd, 'redrawstatus')
  end)
end

---@param bufnr integer
---@param arcadia_root string
---@param lsp_root string
---@param server string
function M.associate(bufnr, arcadia_root, lsp_root, server)
  local entry = buffers[bufnr]
  if not entry or entry.lsp_root ~= lsp_root then
    entry = { arcadia_root = arcadia_root, lsp_root = lsp_root, servers = {} }
    buffers[bufnr] = entry
  end
  entry.servers[server] = true
end

---@param bufnr integer
function M.dissociate(bufnr)
  if buffers[bufnr] then
    buffers[bufnr] = nil
    emit_change()
  end
end

---@param lsp_root string
---@param server string
---@param value ArcadiaLspServerStatus
function M.set(lsp_root, server, value)
  states[lsp_root] = states[lsp_root] or {}
  states[lsp_root][server] = vim.deepcopy(value)
  emit_change()
end

---@param bufnr integer
---@return ArcadiaLspStatus?
function M.get(bufnr)
  local entry = buffers[bufnr]
  if not entry then
    return nil
  end

  local servers = {}
  for server in pairs(entry.servers) do
    servers[server] = vim.deepcopy((states[entry.lsp_root] or {})[server] or { state = 'idle' })
  end
  return {
    arcadia_root = entry.arcadia_root,
    lsp_root = entry.lsp_root,
    servers = servers,
  }
end

---@param bufnr integer
---@param now_ms? number
---@return string
function M.line(bufnr, now_ms)
  local value = M.get(bufnr)
  if not value then
    return ''
  end
  for _, server_status in pairs(value.servers) do
    if server_status.state == 'waiting' then
      local time = now_ms or (vim.uv.hrtime() / 1000000)
      local index = (math.floor(time / 100) % #frames) + 1
      return 'lsp ' .. frames[index]
    end
  end
  return ''
end

function M.clear()
  states = {}
  buffers = {}
end

return M
