local M = {}

---@param lsp_root string
---@param server string
---@return string
function M.data(lsp_root, server)
  local hash = vim.fn.sha256(lsp_root)
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'arcadia-lspconfig', hash, server)
end

---@param server string
---@return string
function M.shared(server)
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'arcadia-lspconfig', server)
end

---@param path string
---@return boolean, string?
function M.ensure(path)
  local result = vim.fn.mkdir(path, 'p')
  if result == 0 and not vim.uv.fs_stat(path) then
    return false, ('cannot create data directory: %s'):format(path)
  end
  return true
end

return M
