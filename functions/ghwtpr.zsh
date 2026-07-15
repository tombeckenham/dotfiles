# Create a worktree to review a GitHub PR and launch Claude with review-pr
# Usage: ghwtpr [-i] <pr-number>
# Detects forks and checks out the PR head (including PRs raised from a
# contributor's fork) via `gh pr checkout`, which wires up the fork remote and
# push config so maintainers can push fixes back when edits are allowed.
# Also gathers staleness info (how far behind the base branch the PR is) and
# feeds it into the review so relevance/out-of-date concerns get assessed.
ghwtpr() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: ghwtpr [-i] <pr-number>"
    echo "  Check out a PR into a worktree and run /pr-review-toolkit:review-pr"
    echo "  -i, --issue  Optional flag before PR number (e.g. ghwtpr -i 42)"
    echo ""
    echo "Handles PRs from forks and reports how out of date the PR is."
    return 0
  fi

  local pr_number
  if [[ "$1" == "-i" || "$1" == "--issue" ]]; then
    pr_number="$2"
    if [[ -z "$pr_number" ]]; then
      echo "Error: -i requires a PR number"
      return 1
    fi
  else
    pr_number="$1"
  fi

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric"
    return 1
  fi

  # Detect if this repo is a fork by comparing origin URL to what gh resolves
  local is_fork=false upstream_repo="" fork_repo=""
  fork_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')
  upstream_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
  if [[ -n "$fork_repo" && -n "$upstream_repo" && "$fork_repo" != "$upstream_repo" ]]; then
    is_fork=true
    echo "Detected fork of $upstream_repo"
  fi

  # The repo that owns the PR. When we're a fork, the PR lives upstream.
  local -a repo_args=()
  $is_fork && repo_args=(-R "$upstream_repo")

  # Fetch PR metadata: branch naming, fork detection, mergeability, freshness.
  local pr_data
  pr_data=$(gh pr view "${repo_args[@]}" "$pr_number" \
    --json headRefName,baseRefName,isCrossRepository,maintainerCanModify,mergeable,mergeStateStatus,createdAt,updatedAt,headRepositoryOwner 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch PR info: $pr_data"
    return 1
  fi
  local head_ref base_ref is_cross can_modify mergeable merge_state created_at updated_at fork_owner
  head_ref=$(echo "$pr_data" | jq -r '.headRefName')
  base_ref=$(echo "$pr_data" | jq -r '.baseRefName')
  is_cross=$(echo "$pr_data" | jq -r '.isCrossRepository')
  can_modify=$(echo "$pr_data" | jq -r '.maintainerCanModify')
  mergeable=$(echo "$pr_data" | jq -r '.mergeable')
  merge_state=$(echo "$pr_data" | jq -r '.mergeStateStatus')
  created_at=$(echo "$pr_data" | jq -r '.createdAt')
  updated_at=$(echo "$pr_data" | jq -r '.updatedAt')
  fork_owner=$(echo "$pr_data" | jq -r '.headRepositoryOwner.login')

  # Check out under the PR's own head branch name. gh ties a local checkout back
  # to its PR by this branch name (plus the remote it configures), so renaming it
  # — e.g. namespacing cross-repo PRs — stops `gh pr view/status/checks` from
  # recognising the worktree as the PR. A clash with an existing local branch is
  # caught by the guard below rather than papered over with a rename.
  local local_branch="$head_ref"
  if [[ "$is_cross" == "true" ]]; then
    echo "PR #${pr_number} is from fork ${fork_owner} (cross-repo)"
  fi

  # Resolve main repo root (works from both main checkout and linked worktrees)
  local repo_root repo_name
  repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  repo_name=$(basename "$repo_root")
  mkdir -p ~/.claude/worktrees
  local worktree_path="$HOME/.claude/worktrees/${repo_name}-${pr_number}"

  # If the worktree already exists, skip straight to opening it
  if [[ -d "$worktree_path" ]]; then
    echo "Worktree already exists at: $worktree_path"
  else
    # Refuse to clobber an existing local branch that isn't ours
    if git show-ref --verify --quiet "refs/heads/${local_branch}"; then
      echo "Error: local branch '${local_branch}' already exists but has no worktree."
      echo "Delete it first (git branch -D ${local_branch}) or resolve manually."
      return 1
    fi

    # Create a detached worktree first, then let `gh pr checkout` populate it.
    # gh handles fork PRs properly: it adds the contributor's fork as a remote,
    # fetches the head branch, sets upstream tracking, and (when the PR allows
    # maintainer edits) configures pushRemote so we can push fixes back.
    echo "Checking out PR #${pr_number} (branch '${local_branch}')..."
    if ! git worktree add --detach "$worktree_path" >/dev/null; then
      echo "Failed to create worktree"
      return 1
    fi

    local -a checkout_args=("$pr_number")
    $is_fork && checkout_args+=(-R "$upstream_repo")
    if ! (cd "$worktree_path" && gh pr checkout "${checkout_args[@]}"); then
      echo "Failed to check out PR #${pr_number}"
      git worktree remove --force "$worktree_path" 2>/dev/null
      git branch -D "$local_branch" 2>/dev/null
      return 1
    fi

    if [[ "$is_cross" == "true" ]]; then
      if [[ "$can_modify" == "true" ]]; then
        echo "Maintainer edits allowed — pushes go back to ${fork_owner}'s fork."
      else
        echo "Note: maintainer edits are NOT allowed on this PR (read-only review)."
      fi
    fi

    echo "Worktree created at: $worktree_path"

    # Run worktree setup
    _worktree_setup "$worktree_path"
  fi

  # Measure how out of date the PR is relative to its base branch so the review
  # can judge whether it's still relevant or needs a rebase.
  local base_fetch_source="origin" behind="?" ahead="?"
  $is_fork && base_fetch_source="https://github.com/${upstream_repo}.git"
  if git -C "$worktree_path" fetch "$base_fetch_source" "$base_ref" 2>/dev/null; then
    behind=$(git -C "$worktree_path" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)
    ahead=$(git -C "$worktree_path" rev-list --count FETCH_HEAD..HEAD 2>/dev/null)
  fi
  echo "PR is ${behind} commit(s) behind ${base_ref}, ${ahead} ahead (mergeable: ${mergeable})"

  # Relevance context appended to the review prompt (no double quotes — this gets
  # embedded in a double-quoted AI command below).
  local relevance_note="PR #${pr_number} freshness context for this review:
- Base branch: ${base_ref}
- Behind ${base_ref} by: ${behind} commit(s)
- Ahead of ${base_ref} by: ${ahead} commit(s)
- Mergeable: ${mergeable} / merge state: ${merge_state}
- From fork: ${is_cross} (owner: ${fork_owner}, maintainer edits: ${can_modify})
- Opened: ${created_at}; last updated: ${updated_at}

As part of the review, assess how relevant and current this PR still is. If it is
significantly behind ${base_ref}, conflicting, or stale, flag it, explain whether
the changes are still applicable to the current codebase, and recommend whether it
needs a rebase or update before it can be merged."

  # A/B: choose claude or grok deterministically per ticket (issue/PR mod 2; fallback mod of datetime)
  local selector="${pr_number}"
  [[ -z "$selector" || "$selector" == "0" ]] && selector=$(date +%s)
  local ai_tool="claude"
  if (( selector % 2 == 0 )); then
    ai_tool="grok"
  fi

  # Build the AI command (use grok's /review-pr skill when selected)
  local ai_cmd
  if [[ "$ai_tool" == "grok" ]]; then
    ai_cmd="grok \"/review-pr ${pr_number}

${relevance_note}\""
  else
    ai_cmd="claude \"/pr-review-toolkit:review-pr ${pr_number}

${relevance_note}\""
  fi

  # Open Cursor (via splt), show PICK ME banner, and tile left
  splt "$worktree_path"

  if [[ -n "${TMUX:-}" ]]; then
    # Tmux: launch AI (claude/grok) in a new tmux window (persistent/reattachable)
    tmux new-window -n "${ai_tool}-review-${pr_number}" -c "$worktree_path" "$ai_cmd"
  else
    # No tmux: run AI in current terminal
    cd "$worktree_path" && eval "$ai_cmd"
  fi
}
