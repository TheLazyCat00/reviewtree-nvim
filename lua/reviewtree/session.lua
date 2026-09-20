local config = require("reviewtree.config")
local git = require("reviewtree.git")
local util = require("reviewtree.util")

local M = {}

local function repo_key(common_dir)
  return vim.fn.sha256(util.normalize(common_dir)):sub(1, 16)
end

function M.repo_key(common_dir)
  return repo_key(common_dir)
end

function M.id(source_ref, base_sha, source_sha)
  return table.concat({
    util.slug(source_ref, 36),
    util.short_sha(source_sha),
    "onto",
    util.short_sha(base_sha),
  }, "-")
end

function M.paths(common_dir, id)
  local opts = config.get()
  local key = repo_key(common_dir)
  return {
    metadata = util.join(opts.state_root, key, id .. ".json"),
    worktree = util.join(opts.worktree_root, key, id),
  }
end

function M.refs(id)
  local opts = config.get()
  local branch = opts.branch_prefix .. id
  local tag_root = opts.tag_prefix .. id
  return {
    branch = branch,
    base_tag = tag_root .. "/base",
    source_tag = tag_root .. "/source",
  }
end

function M.save(common_dir, data)
  local p = M.paths(common_dir, data.id)
  util.write_json(p.metadata, data)
end

function M.load(common_dir, id)
  return util.read_json(M.paths(common_dir, id).metadata)
end

function M.find_pair(common_dir, base_sha, source_sha)
  for _, item in ipairs(M.list(common_dir)) do
    if item.base_sha == base_sha and item.source_sha == source_sha then
      return item
    end
  end
  return nil
end

function M.list(common_dir)
  local opts = config.get()
  local dir = util.join(opts.state_root, repo_key(common_dir))
  local files = vim.fn.globpath(dir, "*.json", false, true)
  local sessions = {}
  for _, path in ipairs(files) do
    local value = util.read_json(path)
    if value and value.id then
      table.insert(sessions, value)
    end
  end
  table.sort(sessions, function(a, b)
    return (a.last_opened_at or a.created_at or 0) > (b.last_opened_at or b.created_at or 0)
  end)
  return sessions
end

function M.delete_metadata(common_dir, id)
  local path = M.paths(common_dir, id).metadata
  pcall(os.remove, path)
end

function M.current(cwd)
  local root = git.root(cwd)
  local common = git.common_dir(cwd)
  if not root or not common then
    return nil, common
  end
  for _, item in ipairs(M.list(common)) do
    if util.normalize(item.worktree) == util.normalize(root) then
      return item, common
    end
  end
  return nil, common
end

return M
