local M = {}

function M.trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.normalize(path)
  if not path or path == "" then
    return ""
  end
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  -- Trimming a root separator changes the path's meaning: "/" becomes empty
  -- and "C:\\" becomes "C:". Preserve filesystem roots verbatim.
  if normalized == "/" or normalized:match("^%a:[\\/]$") then
    return normalized
  end
  return normalized:gsub("[\\/]+$", "")
end

local function comparable(path)
  path = M.normalize(path)
  if vim.fn.has("win32") == 1 then
    return path:lower()
  end
  return path
end

function M.is_within(root, path)
  local r = comparable(root)
  local p = comparable(path)
  if r == "" or p == "" then
    return false
  end
  if p == r then
    return true
  end
  local sep = r:sub(-1)
  local prefix = (sep == "/" or sep == "\\") and r or (r .. "/")
  return p:sub(1, #prefix) == prefix
end

function M.relpath(root, path)
  root = M.normalize(root)
  path = M.normalize(path)
  if not M.is_within(root, path) then
    return nil
  end
  if comparable(root) == comparable(path) then
    return "."
  end
  local offset = #root + 1
  if root:sub(-1) ~= "/" and root:sub(-1) ~= "\\" then
    offset = offset + 1
  end
  return path:sub(offset)
end

function M.slug(value, max_len)
  local s = tostring(value or "review")
    :gsub("[^%w%._%-]+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
  if s == "" then
    s = "review"
  end
  max_len = max_len or 48
  if #s > max_len then
    s = s:sub(1, max_len):gsub("%-+$", "")
  end
  return s
end

function M.short_sha(sha)
  return tostring(sha or ""):sub(1, 8)
end

function M.ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

function M.read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return nil
  end
  local decoded_ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok then
    return nil
  end
  return value
end

function M.write_json(path, value)
  M.ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local result = vim.fn.writefile({ vim.json.encode(value) }, path)
  if result ~= 0 then
    error("reviewtree: could not persist session metadata")
  end
end

function M.file_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

function M.join(...)
  return vim.fs.joinpath(...)
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ReviewTree" })
end

return M
