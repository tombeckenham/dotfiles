# Remove a worktree created by ghwt
# Usage: ghwtrm [-i] [<issue-number>]
#   If no issue number is given and cwd is inside a ghwt worktree, removes it.
ghwtrm() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: ghwtrm [-i] [<issue-number>]"
    echo "  Remove a worktree created by ghwt for the given issue"
    echo "  If no issue number is given, targets the current worktree"
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
  elif [[ -n "$1" ]]; then
    issue_number="$1"
  fi

  # If no issue number provided, try to detect from current worktree path
  if [[ -z "$issue_number" ]]; then
    local cwd="$PWD"
    if [[ "$cwd" == "$HOME/.claude/worktrees/"* ]]; then
      local worktree_dir="${cwd#$HOME/.claude/worktrees/}"
      worktree_dir="${worktree_dir%%/*}"
      issue_number="${worktree_dir##*-}"
    fi
    if [[ -z "$issue_number" ]]; then
      echo "Error: No issue number given and not inside a ghwt worktree"
      return 1
    fi
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

  # If we're inside the worktree being removed, cd out first
  if [[ "$PWD" == "$worktree_path"* ]]; then
    local repo_root
    repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
    cd "$repo_root"
  fi

  git worktree remove "$worktree_path" --force 2>/dev/null || git worktree remove "$worktree_path"
  if [[ $? -ne 0 ]]; then
    echo "Failed to remove worktree. Close any open files in Cursor and try again."
    return 1
  fi

  [[ -d "$worktree_path" ]] && rm -rf "$worktree_path"

  echo "Removed worktree: $worktree_path"
}
