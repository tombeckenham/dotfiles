#!/usr/bin/env zsh
# src headRefName refs/pull/<n>/head becomes local branch pr-<n>.
export GHSB_HOME=$(mktemp -d)
export HERDR_WORKTREES_DIR=$(mktemp -d)
source "${0:A:h}/../functions/_ghsb_common.zsh"

fail() { echo "FAIL $1"; exit 1 }

GHSB_FORGE=src
[[ $(_ghsb_pr_local_branch 1893 refs/pull/1893/head) == pr-1893 ]] || fail src-pull-ref
[[ $(_ghsb_pr_local_branch 2145 t3/investigate-handoff-feedback) == t3/investigate-handoff-feedback ]] || fail src-real-branch
GHSB_FORGE=gh
[[ $(_ghsb_pr_local_branch 1893 refs/pull/1893/head) == refs/pull/1893/head ]] || fail gh-keeps-ref
[[ $(_ghsb_pr_local_branch 12 feat/one) == feat/one ]] || fail gh-branch
unset GHSB_FORGE

origin=$(mktemp -d)
git -C "$origin" init -q
git -C "$origin" -c user.email=t@example.com -c user.name=t commit --allow-empty -m init -q
git -C "$origin" update-ref refs/pull/7/head HEAD
want=$(git -C "$origin" rev-parse refs/pull/7/head)

clone=$(mktemp -d)
git clone -q "$origin" "$clone"
cd "$clone" || exit 1

GHSB_FORGE=src
got=$(_ghsb_ensure_src_pull_branch "$clone" 7 refs/pull/7/head) || fail fetch
[[ "$got" == "$want" ]] || fail oid
[[ $(git rev-parse pr-7) == "$want" ]] || fail branch-at-head

# A second call leaves the existing branch where it is.
git commit --allow-empty -m later -q
git update-ref refs/heads/pr-7 HEAD
later=$(git rev-parse HEAD)
got=$(_ghsb_ensure_src_pull_branch "$clone" 7 refs/pull/7/head) || fail fetch-again
[[ "$got" == "$want" ]] || fail fetched-tip
[[ $(git rev-parse pr-7) == "$later" ]] || fail keeps-existing-branch

# Skip/reopen uses pr-<n>, the same name the checkout stores.
repo_name=$(basename "$clone")
git_wt="$HERDR_WORKTREES_DIR/$repo_name/pr-7"
mkdir -p "$(dirname "$git_wt")"
git worktree add -q "$git_wt" pr-7
[[ $(_ghsb_pr_review_action 7 pr-7 "" "") == reopen ]] || fail reopen-pr-n
[[ $(_ghsb_pr_review_action 7 refs/pull/7/head "" "") == new ]] || fail raw-ref-is-not-the-branch
[[ $(_ghsb_pr_review_action 7 pr-7 wOPEN $'pr-7\t'"$git_wt"$'\twOPEN') == skip ]] || fail skip-open

echo OK
