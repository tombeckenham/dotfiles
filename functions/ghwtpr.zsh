# Create a worktree to review a GitHub PR and launch Claude with review-pr
# Usage: ghwtpr [-i] <pr-number>
# Automatically detects forks and fetches PRs from the upstream repo.
ghwtpr() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: ghwtpr [-i] <pr-number>"
    echo "  Check out a PR into a worktree and run /pr-review-toolkit:review-pr"
    echo "  -i, --issue  Optional flag before PR number (e.g. ghwtpr -i 42)"
    echo ""
    echo "Automatically detects forks and fetches PRs from the upstream repo."
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

  # Fetch PR metadata to determine branch naming
  local -a pr_view_args=()
  $is_fork && pr_view_args=(-R "$upstream_repo")
  local pr_data
  pr_data=$(gh pr view "${pr_view_args[@]}" "$pr_number" --json headRefName,isCrossRepository 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch PR info: $pr_data"
    return 1
  fi
  local head_ref is_cross local_branch
  head_ref=$(echo "$pr_data" | jq -r '.headRefName')
  is_cross=$(echo "$pr_data" | jq -r '.isCrossRepository')
  # Cross-repo PRs are snapshots from a contributor's fork — namespace to avoid
  # clobbering any local branch of the same name
  if [[ "$is_cross" == "true" ]]; then
    local_branch="pr-${pr_number}-${head_ref}"
  else
    local_branch="$head_ref"
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

    # Fetch the PR head into a local branch
    local fetch_source="origin"
    $is_fork && fetch_source="https://github.com/${upstream_repo}.git"
    echo "Fetching PR #${pr_number} into branch '${local_branch}'..."
    git fetch "$fetch_source" "refs/pull/${pr_number}/head:refs/heads/${local_branch}"
    if [[ $? -ne 0 ]]; then
      echo "Failed to fetch PR #${pr_number}"
      return 1
    fi

    # Create the worktree on the PR branch
    git worktree add "$worktree_path" "$local_branch"
    if [[ $? -ne 0 ]]; then
      echo "Failed to create worktree"
      git branch -D "$local_branch" 2>/dev/null
      return 1
    fi

    echo "Worktree created at: $worktree_path"

    # Run worktree setup
    _worktree_setup "$worktree_path"
  fi

  # Build the claude command to run the review slash command
  local claude_cmd="claude \"/pr-review-toolkit:review-pr ${pr_number}\""

  # Open Cursor and tile left
  cursor --new-window "$worktree_path"
  splt

  if [[ -n "${TMUX:-}" ]]; then
    # Tmux: launch Claude in a new tmux window (persistent/reattachable)
    tmux new-window -n "review-${pr_number}" -c "$worktree_path" "$claude_cmd"
  else
    # No tmux: run Claude in current terminal
    cd "$worktree_path" && eval "$claude_cmd"
  fi
}
