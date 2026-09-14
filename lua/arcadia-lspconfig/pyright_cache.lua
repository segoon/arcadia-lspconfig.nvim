local M = {}

---@class ArcadiaPyrightCache
---@field project_dir string
---@field extra_paths string[]

---@param path string
---@return table?, string?
local function decode_file(path)
  local handle, open_error = io.open(path, 'rb')
  if not handle then
    return nil, open_error
  end
  local contents = handle:read '*a'
  handle:close()
  local ok, value = pcall(vim.json.decode, contents)
  if not ok or type(value) ~= 'table' then
    return nil, 'file is not a valid JSON object'
  end
  return value
end

---@param value unknown
---@return boolean
local function is_string_list(value)
  if type(value) ~= 'table' or not vim.islist(value) then
    return false
  end
  for _, item in ipairs(value) do
    if type(item) ~= 'string' then
      return false
    end
  end
  return true
end

---@param path string
---@return ArcadiaPyrightCache?, string?
function M.read(path)
  local value, decode_error = decode_file(path)
  if not value then
    return nil, decode_error
  end
  if type(value.project_dir) ~= 'string' or not is_string_list(value.extra_paths) then
    return nil, 'cached Pyright configuration has an invalid schema'
  end
  local stat = vim.uv.fs_stat(value.project_dir)
  if not stat or stat.type ~= 'directory' then
    return nil, 'cached Pyright project directory does not exist'
  end
  return { project_dir = value.project_dir, extra_paths = value.extra_paths }
end

---@param workspace_path string
---@param project_dir string
---@return ArcadiaPyrightCache?, string?
function M.from_workspace(workspace_path, project_dir)
  local workspace, decode_error = decode_file(workspace_path)
  if not workspace then
    return nil, ('cannot read generated workspace: %s'):format(decode_error or 'unknown error')
  end
  local settings = workspace.settings
  local extra_paths = type(settings) == 'table' and settings['python.analysis.extraPaths'] or nil
  if not is_string_list(extra_paths) then
    return nil, 'generated workspace has no valid python.analysis.extraPaths list'
  end
  return { project_dir = project_dir, extra_paths = extra_paths }
end

---@param path string
---@param value ArcadiaPyrightCache
---@param revision integer
---@return boolean?, string?
function M.install(path, value, revision)
  local temporary = path .. ('.tmp.%d'):format(revision)
  local handle, open_error = io.open(temporary, 'wb')
  if not handle then
    return nil, ('cannot write Pyright cache: %s'):format(open_error or 'unknown error')
  end
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    handle:close()
    vim.uv.fs_unlink(temporary)
    return nil, ('cannot encode Pyright cache: %s'):format(encoded)
  end
  handle:write(encoded)
  handle:close()
  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    vim.uv.fs_unlink(temporary)
    return nil, ('cannot replace Pyright cache: %s'):format(rename_error or 'unknown error')
  end
  return true
end

return M
