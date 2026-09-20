#!/usr/bin/env bash
set -euo pipefail

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
repo="$root/repo"
worktree="$root/review"

git init -q -b main "$repo"
git -C "$repo" config user.name "ReviewTree CI"
git -C "$repo" config user.email "reviewtree@example.invalid"

cat > "$repo/code.txt" <<'TXT'
one
two
three
TXT
cat > "$repo/docs.txt" <<'TXT'
old docs
TXT
git -C "$repo" add .
git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

git -C "$repo" switch -q -c feature
cat > "$repo/code.txt" <<'TXT'
one
new parser logic
three
TXT
rm "$repo/docs.txt"
cat > "$repo/new.txt" <<'TXT'
brand new file
second line
TXT
git -C "$repo" add -A
git -C "$repo" commit -q -m feature
source="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" switch -q main

git -C "$repo" worktree add -q -b reviewtree/test "$worktree" "$base"
git -C "$worktree" merge --squash --no-commit "$source" >/dev/null
git -C "$worktree" reset --mixed HEAD >/dev/null
while IFS= read -r -d '' path; do
  git -C "$worktree" add -N -- "$path"
done < <(git -C "$worktree" ls-files --others --exclude-standard -z)

git -C "$repo" tag reviewtree/test/base "$base"
git -C "$repo" tag reviewtree/test/source "$source"

git -C "$worktree" diff --quiet HEAD -- && {
  echo "expected review changes" >&2
  exit 1
}

names="$(git -C "$worktree" diff --name-only HEAD -- | sort)"
expected=$'code.txt\ndocs.txt\nnew.txt'
[[ "$names" == "$expected" ]] || {
  printf 'unexpected changed files:\n%s\n' "$names" >&2
  exit 1
}

# Mark one file reviewed. The remaining working tree must survive the commit.
git -C "$worktree" add -- code.txt
git -C "$worktree" commit -q -m 'reviewtree: reviewed code'
remaining="$(git -C "$worktree" diff --name-only HEAD -- | sort)"
expected_remaining=$'docs.txt\nnew.txt'
[[ "$remaining" == "$expected_remaining" ]] || {
  printf 'unexpected remaining changes:\n%s\n' "$remaining" >&2
  exit 1
}

[[ "$(git -C "$repo" rev-parse reviewtree/test/base)" == "$base" ]]
[[ "$(git -C "$repo" rev-parse reviewtree/test/source)" == "$source" ]]
[[ "$(git -C "$worktree" rev-list --count reviewtree/test/base..HEAD)" == "1" ]]

echo "workflow test passed"
