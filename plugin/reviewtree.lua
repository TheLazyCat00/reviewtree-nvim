if vim.g.loaded_reviewtree == 1 then
  return
end
vim.g.loaded_reviewtree = 1

vim.api.nvim_create_user_command("ReviewTree", function(opts)
  require("reviewtree").command(opts)
end, {
  nargs = "*",
  bang = true,
  complete = function(arg_lead, cmd_line)
    return require("reviewtree").complete(arg_lead, cmd_line)
  end,
  desc = "Review a Git ref as a post-merge working tree",
})
