# reviewtree.nvim

Review a Git branch or commit as the repository that would exist **after it is merged**, instead of reading a traditional old-vs-new diff.

ReviewTree creates a persistent auxiliary Git worktree, squash-merges the ref you want to review into your current `HEAD`, then resets the index. The result is a normal repository checkout where Git/Gitsigns marks the still-unreviewed code.

As you review hunks, stage and commit them. Those commits become the review state: committed hunks stop appearing as changes, while everything you have not reviewed remains visible in the working tree. Leaving the review preserves both the local review commits and the remaining dirty tree, so opening the same diff later continues exactly where you stopped.

## Why

A normal Git diff is organized around text history. ReviewTree is organized around the resulting program:

- browse the entire repository, not only changed files;
- use normal LSP, Tree-sitter, references, search, and editor navigation;
- see changed/new/deleted regions through ordinary Git signs;
- progressively mark hunks reviewed by committing them;
- keep review state as ordinary local Git history rather than plugin-owned bookkeeping.

## Requirements

- Neovim 0.10+
- Git
- Optional: [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for gutter signs and hunk staging

ReviewTree has no runtime dependencies.

## Install

### lazy.nvim

```lua
{
  "TheLazyCat00/reviewtree-nvim",
  opts = {},
}
```

Calling `setup()` is optional; the defaults work without configuration.

## Workflow

Suppose you are on `main` and want to review `feature/parser`:

```vim
:ReviewTree diff feature/parser
```

The **current `HEAD` is the base**. The argument is the incoming branch or commit.

ReviewTree creates a persistent review worktree and local refs, then opens the worktree in a new Neovim tab. Internally the initial state is equivalent to:

```text
review branch HEAD = main at review start
working tree       = result of squash-merging feature/parser
index              = reset to review branch HEAD
```

New files are marked intent-to-add so Git/Gitsigns can represent them as additions and stage them hunk-by-hunk.

Now review normally. With Gitsigns, for example:

```vim
:Gitsigns stage_hunk
```

Then commit the staged hunks:

```vim
:ReviewTree commit
```

or use ordinary `git commit`. After the commit, those hunks are part of the review branch `HEAD`, so Gitsigns only shows what remains unreviewed.

Leave the review with:

```vim
:ReviewTree return
```

This returns to your original checkout. It **does not delete** the review worktree, dirty changes, commits, branch, or tags.

Run the exact same diff again:

```vim
:ReviewTree diff feature/parser
```

If the base and source resolve to the same immutable commit pair as before, ReviewTree reopens the existing session and you continue where you stopped. If either branch has moved, ReviewTree creates a new session rather than silently changing the old review.

## Commands

```text
:ReviewTree diff <ref>          Start or resume a review
:ReviewTree return              Return to the original checkout; preserve review state
:ReviewTree status              Show base/source, reviewed commits, and remaining changes
:ReviewTree sessions            List saved review sessions for this repository
:ReviewTree commit [message]    Commit staged reviewed hunks locally
:ReviewTree discard [session]   Permanently delete a review session
:ReviewTree discard! [session]  Delete without confirmation
```

`commit` defaults to `reviewtree: reviewed hunks` when no message is supplied.

## Git representation

For a session named roughly:

```text
feature-parser-3f91c2ab-onto-a104772c
```

ReviewTree creates:

```text
branch: reviewtree/feature-parser-3f91c2ab-onto-a104772c
 tag:   reviewtree/feature-parser-3f91c2ab-onto-a104772c/base
 tag:   reviewtree/feature-parser-3f91c2ab-onto-a104772c/source
```

The base tag permanently records where the target branch was when review started. The source tag records exactly what incoming commit was reviewed. Review commits are normal commits on the local `reviewtree/...` branch.

Nothing is pushed automatically. If you intentionally want to publish a review branch or tag, ordinary Git commands still work.

## Persistent worktrees

Worktrees and lightweight session metadata live under Neovim's data directory by default:

```text
stdpath("data")/reviewtree/worktrees/
stdpath("data")/reviewtree/sessions/
```

The metadata only records how to find a session (base/source SHAs, refs, worktree path, branch, tags). **Review progress itself lives in Git**: reviewed hunks are commits and unreviewed hunks are the working tree.

`:ReviewTree discard` removes the auxiliary worktree, review branch, local tags, and metadata. `:ReviewTree return` never does.

## Configuration

```lua
require("reviewtree").setup({
  -- Persistent worktrees and session metadata.
  worktree_root = vim.fs.joinpath(vim.fn.stdpath("data"), "reviewtree", "worktrees"),
  state_root = vim.fs.joinpath(vim.fn.stdpath("data"), "reviewtree", "sessions"),

  branch_prefix = "reviewtree/",
  tag_prefix = "reviewtree/",

  -- Open the corresponding file in the review worktree when possible.
  open_current_file = true,

  -- Ask before destroying a persistent session.
  confirm_discard = true,

  -- Used by :ReviewTree commit with no explicit message.
  commit_message = "reviewtree: reviewed hunks",
})
```

## Merge conflicts

ReviewTree intentionally uses Git's real merge machinery so the checkout represents the post-merge repository, not merely `git diff base...head`.

The first version requires the incoming ref to squash-merge cleanly. If Git reports a merge conflict while creating a session, ReviewTree removes the temporary review worktree and leaves your original checkout untouched.

## Safety

ReviewTree never checks out the incoming ref in your normal worktree and never modifies your current branch. Review sessions happen in separate `git worktree` checkouts.

Your original checkout may even contain uncommitted work; it is not used as the merge workspace. The immutable current `HEAD` is used as the review base.

The only refs ReviewTree creates are its namespaced local branch and tags. No remote operations or pushes are performed.
