local util = require("reviewtree.util")

local M = {}

local function command(args)
  local out = { "git" }
  vim.list_extend(out, args)
  return out
end

function M.run(cwd, args, opts)
  opts = opts or {}
  local result = vim.system(command(args), {
    cwd = cwd,
    text = true,
    stdin = opts.stdin,
  }):wait()

  local stdout = result.stdout or ""
  local stderr = result.stderr or ""
  if not opts.raw then
    stdout = util.trim(stdout)
    stderr = util.trim(stderr)
  end
  return {
    code = result.code,
    stdout = stdout,
    stderr = stderr,
  }
end

function M.must(cwd, args, context)
  local result = M.run(cwd, args)
  if result.code ~= 0 then
    local detail = result.stderr ~= "" and result.stderr or result.stdout
    error(("reviewtree: %s%s"):format(context or "git command failed", detail ~= "" and (": " .. detail) or ""))
  end
  return result.stdout
end

function M.root(cwd)
  local result = M.run(cwd, { "rev-parse", "--show-toplevel" })
  if result.code ~= 0 or result.stdout == "" then
    return nil
  end
  return util.normalize(result.stdout)
end

function M.common_dir(cwd)
  local result = M.run(cwd, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if result.code ~= 0 or result.stdout == "" then
    return nil
  end
  return util.normalize(result.stdout)
end

function M.resolve(cwd, ref)
  local result = M.run(cwd, { "rev-parse", "--verify", ref .. "^{commit}" })
  if result.code ~= 0 or result.stdout == "" then
    return nil, result.stderr ~= "" and result.stderr or ("unknown revision: " .. ref)
  end
  return result.stdout
end

function M.current_ref(cwd)
  local branch = M.run(cwd, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  if branch.code == 0 and branch.stdout ~= "" then
    return branch.stdout
  end
  return M.must(cwd, { "rev-parse", "--short", "HEAD" }, "couldn't resolve current HEAD")
end

function M.ref_exists(cwd, ref)
  return M.run(cwd, { "show-ref", "--verify", "--quiet", ref }).code == 0
end

function M.worktree_add(cwd, branch, path, base_sha)
  return M.run(cwd, { "worktree", "add", "-b", branch, path, base_sha })
end

function M.worktree_add_existing(cwd, branch, path)
  return M.run(cwd, { "worktree", "add", path, branch })
end

function M.worktree_remove(cwd, path, force)
  local args = { "worktree", "remove" }
  if force then
    table.insert(args, "--force")
  end
  table.insert(args, path)
  return M.run(cwd, args)
end

function M.worktree_prune(cwd)
  return M.run(cwd, { "worktree", "prune" })
end

function M.delete_branch(cwd, branch)
  return M.run(cwd, { "branch", "-D", branch })
end

function M.delete_tag(cwd, tag)
  return M.run(cwd, { "tag", "-d", tag })
end

function M.create_tag(cwd, tag, sha)
  return M.run(cwd, { "tag", "-f", tag, sha })
end

function M.merge_squash(cwd, source_sha)
  return M.run(cwd, { "merge", "--squash", "--no-commit", source_sha })
end

function M.reset_mixed(cwd)
  return M.run(cwd, { "reset", "--mixed", "HEAD" })
end

function M.reset_hard(cwd, ref)
  return M.run(cwd, { "reset", "--hard", ref })
end

function M.clean(cwd)
  return M.run(cwd, { "clean", "-fd" })
end

function M.changed_files(cwd)
  local result = M.run(cwd, { "diff", "--name-only", "HEAD", "--" })
  if result.code ~= 0 or result.stdout == "" then
    return {}
  end
  return vim.split(result.stdout, "\n", { plain = true, trimempty = true })
end

function M.untracked_files(cwd)
  local result = M.run(cwd, { "ls-files", "--others", "--exclude-standard", "-z" }, { raw = true })
  if result.code ~= 0 or result.stdout == "" then
    return {}
  end
  return vim.split(result.stdout, "\0", { plain = true, trimempty = true })
end

function M.intent_to_add(cwd, paths)
  if #paths == 0 then
    return true
  end
  local batch_size = 100
  for i = 1, #paths, batch_size do
    local args = { "add", "-N", "--" }
    for j = i, math.min(i + batch_size - 1, #paths) do
      table.insert(args, paths[j])
    end
    local result = M.run(cwd, args)
    if result.code ~= 0 then
      return false, result.stderr ~= "" and result.stderr or result.stdout
    end
  end
  return true
end

function M.has_changes(cwd)
  return M.run(cwd, { "diff", "--quiet", "HEAD", "--" }).code ~= 0
end

function M.has_staged(cwd)
  return M.run(cwd, { "diff", "--cached", "--quiet", "HEAD", "--" }).code ~= 0
end

function M.commit(cwd, message)
  return M.run(cwd, { "commit", "-m", message })
end

function M.shortstat(cwd)
  local result = M.run(cwd, { "diff", "--shortstat", "HEAD", "--" })
  return result.code == 0 and result.stdout or ""
end

function M.numstat(cwd)
  local result = M.run(cwd, { "diff", "--numstat", "HEAD", "--" })
  if result.code ~= 0 or result.stdout == "" then
    return {}
  end
  return vim.split(result.stdout, "\n", { plain = true, trimempty = true })
end

function M.commit_count(cwd, from_ref)
  local result = M.run(cwd, { "rev-list", "--count", from_ref .. "..HEAD" })
  if result.code ~= 0 then
    return 0
  end
  return tonumber(result.stdout) or 0
end

function M.refs(cwd)
  local result = M.run(cwd, {
    "for-each-ref",
    "--format=%(refname:short)",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
  })
  if result.code ~= 0 or result.stdout == "" then
    return {}
  end
  return vim.split(result.stdout, "\n", { plain = true, trimempty = true })
end

return M
