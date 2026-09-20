local config = require("reviewtree.config")
local git = require("reviewtree.git")
local session = require("reviewtree.session")
local util = require("reviewtree.util")

local M = {}

local return_state = nil

local function fail(message)
  util.notify(message, vim.log.levels.ERROR)
end

local function refresh_gitsigns()
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok and type(gitsigns.refresh) == "function" then
    pcall(gitsigns.refresh)
  end
end

local function repo_context()
  local cwd = vim.fn.getcwd()
  local root = git.root(cwd)
  if not root then
    error("reviewtree: current directory is not inside a Git repository")
  end
  local common = git.common_dir(root)
  if not common then
    error("reviewtree: couldn't resolve Git common directory")
  end
  return root, common
end

local function current_file_relative(root)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return nil
  end
  return util.relpath(root, name)
end

local function remember_return_state(root)
  return {
    tab = vim.api.nvim_get_current_tabpage(),
    cwd = vim.fn.getcwd(),
    root = root,
    file = current_file_relative(root),
    cursor = vim.api.nvim_win_get_cursor(0),
  }
end

local function open_review(session_data, origin)
  return_state = origin or return_state
  session_data.last_opened_at = os.time()
  session.save(session_data.common_dir, session_data)

  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(session_data.worktree))

  local rel = origin and origin.file or nil
  if config.get().open_current_file and rel and rel ~= "." then
    local candidate = util.join(session_data.worktree, rel)
    if util.file_exists(candidate) then
      vim.cmd("edit " .. vim.fn.fnameescape(candidate))
      if origin.cursor then
        pcall(vim.api.nvim_win_set_cursor, 0, origin.cursor)
      end
    end
  end

  util.notify(("Reviewing %s onto %s\n%s"):format(
    session_data.source_ref,
    session_data.base_ref,
    session_data.worktree
  ))
end

local function cleanup_failed_session(root, data)
  pcall(function()
    git.worktree_remove(root, data.worktree, true)
  end)
  pcall(function()
    git.worktree_prune(root)
  end)
  pcall(function()
    git.delete_branch(root, data.branch)
  end)
  pcall(function()
    git.delete_tag(root, data.base_tag)
  end)
  pcall(function()
    git.delete_tag(root, data.source_tag)
  end)
  pcall(function()
    session.delete_metadata(data.common_dir, data.id)
  end)
end

local function create_session(root, common, source_ref, source_sha, base_sha, base_ref)
  local id = session.id(source_ref, base_sha, source_sha)
  local paths = session.paths(common, id)
  local refs = session.refs(id)
  local data = {
    version = 1,
    id = id,
    common_dir = common,
    origin_root = root,
    worktree = paths.worktree,
    branch = refs.branch,
    base_tag = refs.base_tag,
    source_tag = refs.source_tag,
    base_ref = base_ref,
    base_sha = base_sha,
    source_ref = source_ref,
    source_sha = source_sha,
    created_at = os.time(),
    last_opened_at = os.time(),
  }

  util.ensure_dir(vim.fn.fnamemodify(paths.worktree, ":h"))

  if git.ref_exists(root, "refs/heads/" .. refs.branch) then
    error("reviewtree: session branch already exists without usable metadata: " .. refs.branch)
  end

  local added = git.worktree_add(root, refs.branch, paths.worktree, base_sha)
  if added.code ~= 0 then
    error("reviewtree: couldn't create review worktree: " .. (added.stderr ~= "" and added.stderr or added.stdout))
  end

  local merged = git.merge_squash(paths.worktree, source_sha)
  if merged.code ~= 0 then
    cleanup_failed_session(root, data)
    error("reviewtree: the incoming ref does not squash-merge cleanly onto the current HEAD: " .. (merged.stderr ~= "" and merged.stderr or merged.stdout))
  end

  local reset = git.reset_mixed(paths.worktree)
  if reset.code ~= 0 then
    cleanup_failed_session(root, data)
    error("reviewtree: couldn't reset the review index: " .. (reset.stderr ~= "" and reset.stderr or reset.stdout))
  end

  local untracked = git.untracked_files(paths.worktree)
  local ok, intent_err = git.intent_to_add(paths.worktree, untracked)
  if not ok then
    cleanup_failed_session(root, data)
    error("reviewtree: couldn't mark added files as intent-to-add: " .. tostring(intent_err))
  end

  if not git.has_changes(paths.worktree) then
    cleanup_failed_session(root, data)
    error("reviewtree: this ref produces no changes when merged onto the current HEAD")
  end

  local base_tag = git.create_tag(root, refs.base_tag, base_sha)
  if base_tag.code ~= 0 then
    cleanup_failed_session(root, data)
    error("reviewtree: couldn't create base tag: " .. (base_tag.stderr ~= "" and base_tag.stderr or base_tag.stdout))
  end
  local source_tag = git.create_tag(root, refs.source_tag, source_sha)
  if source_tag.code ~= 0 then
    cleanup_failed_session(root, data)
    error("reviewtree: couldn't create source tag: " .. (source_tag.stderr ~= "" and source_tag.stderr or source_tag.stdout))
  end

  local saved, save_err = pcall(session.save, common, data)
  if not saved then
    cleanup_failed_session(root, data)
    error(save_err)
  end
  return data
end

function M.diff(source_ref)
  if not source_ref or source_ref == "" then
    fail("Usage: :ReviewTree diff <branch-or-commit>")
    return
  end

  local ok, err = pcall(function()
    local root, common = repo_context()
    local active = session.current(root)
    if active then
      error("reviewtree: already inside a review session; use :ReviewTree return first")
    end

    local base_sha = git.must(root, { "rev-parse", "HEAD" }, "couldn't resolve current HEAD")
    local base_ref = git.current_ref(root)
    local source_sha, resolve_err = git.resolve(root, source_ref)
    if not source_sha then
      error("reviewtree: " .. tostring(resolve_err))
    end
    if source_sha == base_sha then
      error("reviewtree: incoming ref resolves to the current HEAD")
    end

    local id = session.id(source_ref, base_sha, source_sha)
    local existing = session.find_pair(common, base_sha, source_sha) or session.load(common, id)
    local origin = remember_return_state(root)

    if existing then
      if not util.file_exists(existing.worktree) then
        error(("reviewtree: session %s exists but its worktree is missing; discard that session before recreating it"):format(id))
      end
      existing.common_dir = common
      open_review(existing, origin)
      return
    end

    local data = create_session(root, common, source_ref, source_sha, base_sha, base_ref)
    open_review(data, origin)
  end)

  if not ok then
    fail(tostring(err):gsub("^.-reviewtree:", "ReviewTree:"))
  end
end

function M.return_to_origin()
  local ok, err = pcall(function()
    local cwd = vim.fn.getcwd()
    local active = session.current(cwd)
    if not active then
      error("reviewtree: current directory is not a ReviewTree worktree")
    end

    local current_rel = current_file_relative(active.worktree)
    local state = return_state
    local target_root = (state and state.root) or active.origin_root
    if not target_root or not util.file_exists(target_root) then
      error("reviewtree: original worktree is no longer available")
    end

    local current_tab = vim.api.nvim_get_current_tabpage()
    if state and state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      if current_tab ~= state.tab and vim.api.nvim_tabpage_is_valid(current_tab) then
        pcall(vim.api.nvim_set_current_tabpage, current_tab)
        local closed = pcall(vim.cmd, "tabclose")
        vim.api.nvim_set_current_tabpage(state.tab)
        if not closed then
          util.notify("Review worktree was left open because the review tab could not be closed", vim.log.levels.WARN)
        end
      end
    else
      vim.cmd("tcd " .. vim.fn.fnameescape(target_root))
    end

    if current_rel and current_rel ~= "." then
      local counterpart = util.join(target_root, current_rel)
      if util.file_exists(counterpart) then
        vim.cmd("edit " .. vim.fn.fnameescape(counterpart))
      elseif state and state.file then
        local original = util.join(target_root, state.file)
        if util.file_exists(original) then
          vim.cmd("edit " .. vim.fn.fnameescape(original))
        end
      end
    elseif state and state.file then
      local original = util.join(target_root, state.file)
      if util.file_exists(original) then
        vim.cmd("edit " .. vim.fn.fnameescape(original))
      end
    end

    return_state = nil
    util.notify(("Returned to %s; review session %s is preserved"):format(target_root, active.id))
  end)

  if not ok then
    fail(tostring(err):gsub("^.-reviewtree:", "ReviewTree:"))
  end
end

local function current_session_or_error()
  local active = session.current(vim.fn.getcwd())
  if not active then
    error("reviewtree: current directory is not a ReviewTree worktree")
  end
  return active
end

function M.status()
  local ok, err = pcall(function()
    local active = current_session_or_error()
    local count = git.commit_count(active.worktree, active.base_tag)
    local stat = git.shortstat(active.worktree)
    local remaining = #git.numstat(active.worktree)
    local lines = {
      ("Session: %s"):format(active.id),
      ("Base:    %s (%s)"):format(active.base_ref, util.short_sha(active.base_sha)),
      ("Source:  %s (%s)"):format(active.source_ref, util.short_sha(active.source_sha)),
      ("Reviewed commits: %d"):format(count),
      ("Remaining files:  %d%s"):format(remaining, stat ~= "" and (" · " .. stat) or ""),
      ("Worktree: %s"):format(active.worktree),
      ("Branch:   %s"):format(active.branch),
    }
    util.notify(table.concat(lines, "\n"))
  end)
  if not ok then
    fail(tostring(err):gsub("^.-reviewtree:", "ReviewTree:"))
  end
end

function M.sessions()
  local ok, err = pcall(function()
    local root, common = repo_context()
    local items = session.list(common)
    if #items == 0 then
      util.notify("No ReviewTree sessions for this repository")
      return
    end
    local lines = { "ReviewTree sessions:" }
    for _, item in ipairs(items) do
      local state = util.file_exists(item.worktree) and "saved" or "missing worktree"
      table.insert(lines, ("  %s  %s -> %s  [%s]"):format(item.id, item.source_ref, item.base_ref, state))
    end
    table.insert(lines, ("Repository: %s"):format(root))
    util.notify(table.concat(lines, "\n"))
  end)
  if not ok then
    fail(tostring(err):gsub("^.-reviewtree:", "ReviewTree:"))
  end
end

function M.commit(message)
  local ok, err = pcall(function()
    local active = current_session_or_error()
    if not git.has_staged(active.worktree) then
      error("reviewtree: no staged hunks to commit")
    end
    local msg = util.trim(message)
    if msg == "" then
      msg = config.get().commit_message
    end
    local result = git.commit(active.worktree, msg)
    if result.code ~= 0 then
      error("reviewtree: commit failed: " .. (result.stderr ~= "" and result.stderr or result.stdout))
    end
    vim.cmd("checktime")
    refresh_gitsigns()
    if git.has_changes(active.worktree) then
      local stat = git.shortstat(active.worktree)
      util.notify("Reviewed hunks committed locally" .. (stat ~= "" and (" · remaining: " .. stat) or ""))
    else
      util.notify("Reviewed hunks committed locally · review complete")
    end
  end)
  if not ok then
    fail(tostring(err):gsub("^.-reviewtree:", "ReviewTree:"))
  end
end

local function find_session_for_discard(id)
  local root, common = repo_context()
  local active = session.current(root)
  if active and (not id or id == "" or id == active.id) then
    return active, common
  end
  if id and id ~= "" then
    local found = session.load(common, id)
    if found then
      return found, common
    end
  end
  error("reviewtree: no matching review session")
end

function M.discard(id, force)
  local ok, err = pcall(function()
    local data, common = find_session_for_discard(id)
    if config.get().confirm_discard and not force then
      local answer = vim.fn.confirm(
        ("Delete ReviewTree session %s?\nThis removes its worktree, local review branch, and local tags."):format(data.id),
        "&Delete\n&Cancel",
        2
      )
      if answer ~= 1 then
        return
      end
    end

    local current = session.current(vim.fn.getcwd())
    if current and current.id == data.id then
      M.return_to_origin()
      local still_here = git.root(vim.fn.getcwd())
      if still_here and util.normalize(still_here) == util.normalize(data.worktree) then
        error("reviewtree: could not leave the review worktree; session was not deleted")
      end
    end

    local origin = data.origin_root
    if origin and util.file_exists(origin) then
      git.worktree_remove(origin, data.worktree, true)
      git.worktree_prune(origin)
      git.delete_branch(origin, data.branch)
      git.delete_tag(origin, data.base_tag)
      git.delete_tag(origin, data.source_tag)
    end
    session.delete_metadata(common, data.id)
    util.notify("Deleted ReviewTree session " .. data.id)
  end)
  if not ok then
    fail(tostring(err):gsub("^.-reviewtree:", "ReviewTree:"))
  end
end

local subcommands = { "diff", "return", "status", "sessions", "commit", "discard" }

function M.command(opts)
  local args = opts.fargs or {}
  local sub = args[1]
  if sub == "diff" then
    M.diff(args[2])
  elseif sub == "return" then
    M.return_to_origin()
  elseif sub == "status" then
    M.status()
  elseif sub == "sessions" then
    M.sessions()
  elseif sub == "commit" then
    M.commit(table.concat(vim.list_slice(args, 2), " "))
  elseif sub == "discard" then
    M.discard(args[2], opts.bang)
  else
    util.notify("Usage: :ReviewTree {diff <ref>|return|status|sessions|commit [message]|discard[!] [session]}")
  end
end

function M.complete(arg_lead, cmd_line)
  local words = vim.split(cmd_line, "%s+", { trimempty = true })
  local trailing_space = cmd_line:match("%s$") ~= nil
  if #words == 1 or (#words == 2 and not trailing_space) then
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arg_lead)
    end, subcommands)
  end

  local sub = words[2]
  if sub == "diff" then
    local root = git.root(vim.fn.getcwd())
    if not root then
      return {}
    end
    return vim.tbl_filter(function(ref)
      return not vim.startswith(ref, config.get().branch_prefix) and vim.startswith(ref, arg_lead)
    end, git.refs(root))
  end

  if sub == "discard" then
    local common = git.common_dir(vim.fn.getcwd())
    if not common then
      return {}
    end
    local ids = vim.tbl_map(function(item)
      return item.id
    end, session.list(common))
    return vim.tbl_filter(function(id)
      return vim.startswith(id, arg_lead)
    end, ids)
  end

  return {}
end

function M.setup(opts)
  config.setup(opts)
end

return M
