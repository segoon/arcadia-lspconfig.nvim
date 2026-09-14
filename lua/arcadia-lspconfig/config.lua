local merge = require 'arcadia-lspconfig.merge'

local M = {}

---@type table<string, vim.lsp.Config>
local base_configs = {}
---@type table<string, table<string, vim.lsp.Config>>
local patches = {}
---@type table<string, table<string, integer>>
local revisions = {}

---@param server string
---@param base vim.lsp.Config
function M.capture(server, base)
  base_configs[server] = vim.deepcopy(base)
end

---@param lsp_root string
---@param server string
---@param patch vim.lsp.Config
---@return integer
function M.extend(lsp_root, server, patch)
  patches[lsp_root] = patches[lsp_root] or {}
  patches[lsp_root][server] = merge.apply(patches[lsp_root][server] or {}, patch)
  revisions[lsp_root] = revisions[lsp_root] or {}
  revisions[lsp_root][server] = (revisions[lsp_root][server] or 0) + 1
  return revisions[lsp_root][server]
end

---@param lsp_root string
---@param server string
---@return integer
function M.revision(lsp_root, server)
  return (revisions[lsp_root] or {})[server] or 0
end

---@param lsp_root string
---@param server string
---@return vim.lsp.Config
function M.resolve(lsp_root, server)
  local base = assert(base_configs[server], ('server config was not captured: %s'):format(server))
  local result = merge.apply(base, (patches[lsp_root] or {})[server] or {})
  result.name = server
  result.root_dir = lsp_root
  result.root_markers = nil
  return result
end

---@param server string
---@return vim.lsp.Config?
function M.base(server)
  return base_configs[server] and vim.deepcopy(base_configs[server]) or nil
end

---@param base vim.lsp.Config
---@param bufnr integer
---@param on_dir fun(root_dir?: string)
function M.delegate_root(base, bufnr, on_dir)
  if type(base.root_dir) == 'function' then
    base.root_dir(bufnr, on_dir)
  elseif type(base.root_dir) == 'string' then
    on_dir(base.root_dir)
  elseif base.root_markers then
    on_dir(vim.fs.root(bufnr, base.root_markers))
  else
    on_dir(nil)
  end
end

function M.clear()
  base_configs = {}
  patches = {}
  revisions = {}
end

return M
