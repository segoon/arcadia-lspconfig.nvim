local M = {}

local REVISION_FILE = '.arcadia-revision'

---@class ArcadiaYamakeTransaction
---@field destination string
---@field backup string
---@field had_previous boolean

---@param path string
---@return string?
local function read_line(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path, '', 1)
  if #lines == 0 then
    return nil
  end
  return lines[1]
end

---@param path string
---@return boolean
local function remove(path)
  return vim.fn.delete(path, 'rf') == 0
end

---@param revision string?
---@return boolean
local function valid_revision(revision)
  return type(revision) == 'string' and revision:match '^[0-9a-fA-F]+$' ~= nil and #revision == 40
end

---@param directory string
---@return string
function M.script_path(directory)
  return vim.fs.joinpath(directory, 'out', 'ya-make-lsp.js')
end

---@param directory string
---@return string?
function M.revision(directory)
  local revision = read_line(vim.fs.joinpath(directory, REVISION_FILE))
  if valid_revision(revision) then
    return revision:lower()
  end
end

---@param directory string
---@return boolean
function M.is_valid(directory)
  return vim.fn.filereadable(M.script_path(directory)) == 1 and M.revision(directory) ~= nil
end

---@param output string?
---@return string?
function M.parse_revision(output)
  if type(output) ~= 'string' then
    return nil
  end
  local revision = output:match '^([0-9a-fA-F]+)%s'
  if not valid_revision(revision) then
    return nil
  end
  return revision:lower()
end

---@param destination string
---@param generation integer
---@return ArcadiaYamakeTransaction?, string?
function M.prepare(destination, generation)
  local parent = vim.fs.dirname(destination)
  local created = vim.fn.mkdir(parent, 'p')
  if created == 0 and not vim.uv.fs_stat(parent) then
    return nil, ('cannot create ya-make-lsp data directory: %s'):format(parent)
  end

  local backup = destination .. ('.backup.%d'):format(generation)
  remove(backup)
  local had_previous = vim.uv.fs_stat(destination) ~= nil
  if had_previous then
    local renamed, rename_error = vim.uv.fs_rename(destination, backup)
    if not renamed then
      return nil,
        ('cannot back up ya-make-lsp installation: %s'):format(rename_error or 'unknown error')
    end
  end
  return {
    destination = destination,
    backup = backup,
    had_previous = had_previous,
  }
end

---@param transaction ArcadiaYamakeTransaction
---@param revision string
---@return boolean?, string?
function M.commit(transaction, revision)
  local script = M.script_path(transaction.destination)
  if vim.fn.filereadable(script) ~= 1 then
    return nil, ('exported ya-make-lsp.js is missing: %s'):format(script)
  end
  if not valid_revision(revision) then
    return nil, 'cannot record an invalid ya-make-lsp revision'
  end

  local path = vim.fs.joinpath(transaction.destination, REVISION_FILE)
  local temporary = path .. '.tmp'
  local written = vim.fn.writefile({ revision:lower() }, temporary)
  if written ~= 0 then
    remove(temporary)
    return nil, ('cannot write ya-make-lsp revision: %s'):format(path)
  end
  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    remove(temporary)
    return nil, ('cannot publish ya-make-lsp revision: %s'):format(rename_error or 'unknown error')
  end
  remove(transaction.backup)
  return true
end

---@param transaction ArcadiaYamakeTransaction
---@return boolean?, string?
function M.rollback(transaction)
  remove(transaction.destination)
  if not transaction.had_previous then
    remove(transaction.backup)
    return true
  end
  local renamed, rename_error = vim.uv.fs_rename(transaction.backup, transaction.destination)
  if not renamed then
    return nil,
      ('cannot restore ya-make-lsp installation: %s'):format(rename_error or 'unknown error')
  end
  return true
end

return M
