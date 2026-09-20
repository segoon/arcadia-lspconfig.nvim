local M = {}

local VERSION = 1

---@class ArcadiaProtolsRecord
---@field target_root string
---@field include_paths string[]
---@field covered_files string[]
---@field raw_plan string
---@field updated_at integer

---@class ArcadiaProtolsIndex
---@field version integer
---@field records ArcadiaProtolsRecord[]

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
    return nil, 'file is not valid JSON'
  end
  return value
end

---@param value string
---@param arcadia_root string
---@param cwd? string
---@return string?
local function resolve_path(value, arcadia_root, cwd)
  if type(value) ~= 'string' or value == '' then
    return nil
  end
  if vim.startswith(value, '$(BUILD_ROOT)') then
    return nil
  end
  value = value:gsub('^%$%(SOURCE_ROOT%)', arcadia_root)
  if value:find '%$%(' then
    return nil
  end
  if not vim.startswith(value, '/') then
    if not cwd then
      return nil
    end
    value = vim.fs.joinpath(cwd, value)
  end
  return vim.fs.normalize(value):gsub('/$', '')
end

---@param values string[]
---@param seen table<string, boolean>
---@param value string?
local function append_unique(values, seen, value)
  if value and value ~= '' and not seen[value] then
    seen[value] = true
    values[#values + 1] = value
  end
end

---@param path string
---@param arcadia_root string
---@param target_root string
---@param raw_plan string
---@param updated_at integer
---@return ArcadiaProtolsRecord?, string?
function M.from_plan(path, arcadia_root, target_root, raw_plan, updated_at)
  local plan, decode_error = decode_file(path)
  if not plan then
    return nil, ('cannot read build plan: %s'):format(decode_error or 'unknown error')
  end
  if type(plan.graph) ~= 'table' or not vim.islist(plan.graph) then
    return nil, 'build plan has no valid graph list'
  end

  local include_paths = {}
  local include_seen = {}
  local covered_files = {}
  local covered_seen = {}
  local source_prefix = '$(SOURCE_ROOT)/'
  for _, node in ipairs(plan.graph) do
    if type(node) == 'table' then
      if type(node.inputs) == 'table' then
        for _, input in ipairs(node.inputs) do
          if
            type(input) == 'string'
            and vim.startswith(input, source_prefix)
            and vim.endswith(input, '.proto')
          then
            local relative = input:sub(#source_prefix + 1)
            local absolute = vim.fs.joinpath(arcadia_root, relative)
            append_unique(covered_files, covered_seen, vim.fs.normalize(absolute))
          end
        end
      end
      if type(node.cmds) == 'table' then
        for _, command in ipairs(node.cmds) do
          local arguments = type(command) == 'table' and command.cmd_args or nil
          local is_protoc = false
          if type(arguments) == 'table' then
            for _, argument in ipairs(arguments) do
              if type(argument) == 'string' and argument:match '/protoc$' then
                is_protoc = true
                break
              end
            end
          end
          if is_protoc then
            local cwd = resolve_path(command.cwd, arcadia_root)
            local argument_index = 1
            while argument_index <= #arguments do
              local argument = arguments[argument_index]
              if argument == '--' then
                break
              end
              local root
              if argument == '-I' or argument == '--proto_path' then
                argument_index = argument_index + 1
                root = arguments[argument_index]
              elseif type(argument) == 'string' then
                root = argument:match '^%-I=(.+)$'
                  or argument:match '^%-I(.+)$'
                  or argument:match '^%-%-proto_path=(.+)$'
              end
              local resolved = resolve_path(root, arcadia_root, cwd)
              append_unique(include_paths, include_seen, resolved)
              argument_index = argument_index + 1
            end
          end
        end
      end
    end
  end
  if #include_paths == 0 then
    return nil, 'build plan contains no usable protoc source include paths'
  end
  if #covered_files == 0 then
    return nil, 'build plan contains no covered source .proto files'
  end
  return {
    target_root = vim.fs.normalize(target_root),
    include_paths = include_paths,
    covered_files = covered_files,
    raw_plan = raw_plan,
    updated_at = updated_at,
  }
end

---@param data_dir string
---@return string
local function index_path(data_dir)
  return vim.fs.joinpath(data_dir, 'index.json')
end

---@param data_dir string
---@return ArcadiaProtolsIndex?, string?
function M.read(data_dir)
  local value, decode_error = decode_file(index_path(data_dir))
  if not value then
    return nil, decode_error
  end
  if
    value.version ~= VERSION
    or type(value.records) ~= 'table'
    or not vim.islist(value.records)
  then
    return nil, 'cached Protols index has an invalid schema'
  end
  for _, record in ipairs(value.records) do
    local raw_path = type(record) == 'table' and record.raw_plan or ''
    if
      type(record) ~= 'table'
      or type(record.target_root) ~= 'string'
      or not is_string_list(record.include_paths)
      or not is_string_list(record.covered_files)
      or type(record.raw_plan) ~= 'string'
      or type(record.updated_at) ~= 'number'
      or vim.fn.filereadable(vim.fs.joinpath(data_dir, raw_path)) ~= 1
    then
      return nil, 'cached Protols index has an invalid record'
    end
  end
  return value
end

---@param index ArcadiaProtolsIndex
---@param path string
---@param target_root string
---@return ArcadiaProtolsRecord?
function M.select(index, path, target_root)
  path = vim.fs.normalize(path)
  target_root = vim.fs.normalize(target_root)
  local selected
  for _, record in ipairs(index.records) do
    if vim.tbl_contains(record.covered_files, path) then
      if record.target_root == target_root then
        return record
      end
      if
        not selected
        or record.updated_at > selected.updated_at
        or (record.updated_at == selected.updated_at and record.target_root < selected.target_root)
      then
        selected = record
      end
    end
  end
  return selected
end

---@param data_dir string
---@param temporary_path string
---@param record ArcadiaProtolsRecord
---@param generation string
---@return ArcadiaProtolsIndex?, string?
function M.install(data_dir, temporary_path, record, generation)
  local plans_dir = vim.fs.joinpath(data_dir, 'plans')
  if vim.fn.mkdir(plans_dir, 'p') == 0 and not vim.uv.fs_stat(plans_dir) then
    return nil, 'cannot create Protols plans directory'
  end
  local filename = vim.fn.sha256(record.target_root) .. '.' .. generation .. '.json'
  local raw_name = vim.fs.joinpath('plans', filename)
  local raw_path = vim.fs.joinpath(data_dir, raw_name)
  local renamed, rename_error = vim.uv.fs_rename(temporary_path, raw_path)
  if not renamed then
    return nil, ('cannot install Protols build plan: %s'):format(rename_error or 'unknown error')
  end
  record.raw_plan = raw_name

  local index = M.read(data_dir)
  if not index then
    index = { version = VERSION, records = {} }
  end
  local previous_raw
  local records = {}
  for _, existing in ipairs(index.records) do
    if existing.target_root == record.target_root then
      previous_raw = existing.raw_plan
    else
      records[#records + 1] = existing
    end
  end
  records[#records + 1] = record
  local next_index = { version = VERSION, records = records }
  local temporary_index = index_path(data_dir) .. '.tmp.' .. generation
  local handle, open_error = io.open(temporary_index, 'wb')
  if not handle then
    vim.uv.fs_unlink(raw_path)
    return nil, ('cannot write Protols index: %s'):format(open_error or 'unknown error')
  end
  local ok, encoded = pcall(vim.json.encode, next_index)
  if not ok then
    handle:close()
    vim.uv.fs_unlink(temporary_index)
    vim.uv.fs_unlink(raw_path)
    return nil, ('cannot encode Protols index: %s'):format(encoded)
  end
  handle:write(encoded)
  handle:close()
  local installed, install_error = vim.uv.fs_rename(temporary_index, index_path(data_dir))
  if not installed then
    vim.uv.fs_unlink(temporary_index)
    vim.uv.fs_unlink(raw_path)
    return nil, ('cannot replace Protols index: %s'):format(install_error or 'unknown error')
  end
  if previous_raw and previous_raw ~= raw_name then
    vim.uv.fs_unlink(vim.fs.joinpath(data_dir, previous_raw))
  end
  return next_index
end

---@param data_dir string
---@return string?, string?
function M.ensure_wrappers(data_dir)
  local bin_dir = vim.fs.joinpath(data_dir, 'bin')
  if vim.fn.mkdir(bin_dir, 'p') == 0 and not vim.uv.fs_stat(bin_dir) then
    return nil, 'cannot create Protols wrapper directory'
  end
  local protoc_wrapper = '#!/bin/sh\nexec "$ARCADIA_LSPCONFIG_YA" run '
    .. '"$ARCADIA_LSPCONFIG_ROOT"/contrib/tools/protoc -- "$@"\n'
  local wrappers = {
    ['clang-format'] = '#!/bin/sh\nexec "$ARCADIA_LSPCONFIG_YA" tool clang-format "$@"\n',
    protoc = protoc_wrapper,
  }
  for name, contents in pairs(wrappers) do
    local path = vim.fs.joinpath(bin_dir, name)
    local handle, open_error = io.open(path, 'wb')
    if not handle then
      return nil, ('cannot write Protols wrapper: %s'):format(open_error or 'unknown error')
    end
    handle:write(contents)
    handle:close()
    if vim.fn.setfperm(path, 'rwxr-xr-x') == 0 then
      return nil, ('cannot make Protols wrapper executable: %s'):format(path)
    end
  end
  return bin_dir
end

return M
