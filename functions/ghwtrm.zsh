# Remove a worktree created by ghwt
# Usage: ghwtrm [-i] <issue-number>
ghwtrm() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: ghwtrm [-i] <issue-number>"
    echo "  Remove a worktree created by ghwt for the given issue"
    echo "  -i, --issue  Optional flag before issue number (e.g. ghwtrm -i 42)"
    return 0
  fi

  local issue_number
  if [[ "$1" == "-i" || "$1" == "--issue" ]]; then
    issue_number="$2"
    if [[ -z "$issue_number" ]]; then
      echo "Error: -i requires an issue number"
      return 1
    fi
  elif [[ -z "$1" ]]; then
    echo "Usage: ghwtrm [-i] <issue-number>"
    echo "  Remove a worktree created by ghwt for the given issue"
    return 0
  else
    issue_number="$1"
  fi

  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "Error: Issue number must be numeric"
    return 1
  fi

  local repo_name
  repo_name=$(basename "$(git config --get remote.origin.url 2>/dev/null | sed 's/\.git$//')")
  if [[ -z "$repo_name" ]]; then
    echo "Error: Not in a git repository"
    return 1
  fi

  local worktree_path="$HOME/.claude/worktrees/${repo_name}-${issue_number}"

  if [[ ! -d "$worktree_path" ]]; then
    echo "Error: No worktree found at $worktree_path"
    return 1
  fi

  git worktree remove "$worktree_path" --force 2>/dev/null || git worktree remove "$worktree_path"
  if [[ $? -ne 0 ]]; then
    echo "Failed to remove worktree. Close any open files in Cursor and try again."
    return 1
  fi

  [[ -d "$worktree_path" ]] && rm -rf "$worktree_path"

  echo "Removed worktree: $worktree_path"
}
