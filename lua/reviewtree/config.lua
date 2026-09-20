local M = {}

local function defaults()
  local data = vim.fn.stdpath("data")
  return {
    worktree_root = vim.fs.joinpath(data, "reviewtree", "worktrees"),
    state_root = vim.fs.joinpath(data, "reviewtree", "sessions"),
    branch_prefix = "reviewtree/",
    tag_prefix = "reviewtree/",
    open_current_file = true,
    confirm_discard = true,
    commit_message = "reviewtree: reviewed hunks",
  }
end

M.options = defaults()

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", defaults(), opts or {})
end

function M.get()
  return M.options
end

return M
