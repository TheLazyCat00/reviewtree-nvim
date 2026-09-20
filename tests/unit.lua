local root = assert(os.getenv("REVIEWTREE_ROOT"))
vim.opt.runtimepath:append(root)

local git = require("reviewtree.git")
local session = require("reviewtree.session")
local util = require("reviewtree.util")

assert(util.normalize("/") == "/", "Unix filesystem root must survive normalization")

local base = string.rep("a", 40)
local source_a = string.rep("b", 39) .. "1"
local source_b = string.rep("b", 39) .. "2"
local id_a = session.id("feature/parser", base, source_a)
local id_b = session.id("feature/parser", base, source_b)
assert(id_a ~= id_b, "session ids must include the complete revision identity")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function run(args)
  local result = vim.system(args, { cwd = tmp, text = true }):wait()
  assert(result.code == 0, result.stderr or result.stdout)
end

run({ "git", "init", "-q", "-b", "main" })
run({ "git", "config", "user.name", "ReviewTree CI" })
run({ "git", "config", "user.email", "reviewtree@example.invalid" })
vim.fn.writefile({ "base" }, tmp .. "/base.txt")
run({ "git", "add", "base.txt" })
run({ "git", "commit", "-q", "-m", "base" })

local magic = ":(exclude)literal.txt"
vim.fn.writefile({ "new" }, tmp .. "/" .. magic)
local ok, err = git.intent_to_add(tmp, { magic })
assert(ok, err)

local diff = git.run(tmp, { "diff", "--name-only", "HEAD", "--" })
assert(diff.code == 0, diff.stderr)
assert(diff.stdout == magic, "literal pathspec filename was not marked intent-to-add")

vim.fn.delete(tmp, "rf")
