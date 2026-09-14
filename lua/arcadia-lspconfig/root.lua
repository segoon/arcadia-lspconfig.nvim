local M = {}

---@class ArcadiaLspRoots
---@field arcadia_root? string
---@field lsp_root? string

---@type table<string, ArcadiaLspRoots>
local cache = {}

---@param path string
---@return boolean
local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

---@param directory string
---@return string?
local function parent(directory)
  local value = vim.fs.dirname(directory)
  if not value or value == directory then
    return nil
  end
  return value
end

---@param start string
---@param marker fun(directory: string): boolean
---@param stop? string
---@return string?
local function ascend(start, marker, stop)
  local directory = start
  while directory do
    if marker(directory) then
      return directory
    end
    if stop and directory == stop then
      break
    end
    directory = parent(directory)
  end
end

---@param path string
---@return ArcadiaLspRoots
function M.find(path)
  if type(path) ~= 'string' or path == '' then
    return {}
  end

  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if cache[path] then
    return vim.deepcopy(cache[path])
  end

  local start = vim.fs.dirname(path)
  if not start then
    cache[path] = {}
    return {}
  end

  local arcadia_root = ascend(start, function(directory)
    return exists(vim.fs.joinpath(directory, '.arc', 'HEAD'))
  end)
  if not arcadia_root then
    cache[path] = {}
    return {}
  end

  local lsp_root = ascend(start, function(directory)
    return exists(vim.fs.joinpath(directory, 'ya.make'))
  end, arcadia_root)

  cache[path] = { arcadia_root = arcadia_root, lsp_root = lsp_root }
  return vim.deepcopy(cache[path])
end

function M.clear_cache()
  cache = {}
end

return M
