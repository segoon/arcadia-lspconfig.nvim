local M = {}

---@param path string
---@return string?, string?
local function read(path)
  local handle, open_error = io.open(path, 'rb')
  if not handle then
    return nil, open_error
  end
  local contents = handle:read '*a'
  handle:close()
  return contents
end

---@param path string
---@return boolean
function M.is_valid(path)
  local contents = read(path)
  if not contents then
    return false
  end
  local ok, decoded = pcall(vim.json.decode, contents)
  return ok and type(decoded) == 'table' and vim.islist(decoded)
end

---@param temporary_path string
---@param destination_path string
---@return boolean? changed
---@return string? error
function M.install(temporary_path, destination_path)
  local contents, read_error = read(temporary_path)
  if not contents then
    return nil,
      ('cannot read generated compilation database: %s'):format(read_error or 'unknown error')
  end

  local ok, decoded = pcall(vim.json.decode, contents)
  if not ok or type(decoded) ~= 'table' or not vim.islist(decoded) then
    vim.uv.fs_unlink(temporary_path)
    return nil, 'generated compilation database is not a valid JSON array'
  end

  local current = read(destination_path)
  if current == contents then
    vim.uv.fs_unlink(temporary_path)
    return false
  end

  local renamed, rename_error = vim.uv.fs_rename(temporary_path, destination_path)
  if not renamed then
    vim.uv.fs_unlink(temporary_path)
    return nil, ('cannot replace compilation database: %s'):format(rename_error or 'unknown error')
  end
  return true
end

return M
