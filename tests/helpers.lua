local M = {}

---@return string
function M.tempdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, 'p')
  return path
end

---@param path string
---@param contents? string
function M.write(path, contents)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ contents or '' }, path)
end

---@param path string
function M.cleanup(path)
  vim.fn.delete(path, 'rf')
end

return M
