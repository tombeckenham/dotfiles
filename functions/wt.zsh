# Create a worktree for an existing branch (without GitHub issue)
# Usage: wt <branch-name>
wt() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: wt <branch-name>"
    echo "  Create a Herdr worktree for an existing branch"
    return 0
  fi

  local branch_name="$1"

  if ! git show-ref --verify --quiet refs/heads/"$branch_name"; then
    if ! git show-ref --verify --quiet refs/remotes/origin/"$branch_name"; then
      echo "Error: Branch '$branch_name' does not exist locally or remotely"
      return 1
    fi

    echo "Fetching branch '$branch_name' from remote..."
    git fetch origin "$branch_name"
    if [[ $? -ne 0 ]]; then
      echo "Failed to fetch branch '$branch_name' from remote"
      return 1
    fi
  fi

  local repo_root repo_name sanitized_branch_name worktree_path
  repo_root=$(_ghsb_repo_root)
  repo_name=$(basename "$repo_root")
  sanitized_branch_name=$(_ghsb_herdr_branch_slug "$branch_name")
  _ghsb_herdr_wt_ensure_branch "$repo_root" "$branch_name" "${repo_name}-${sanitized_branch_name}" || return 1
  worktree_path="${GHSB_HERDR_WT[path]}"

  open -a "Cursor" "$worktree_path"
  sleep 0.8
  osascript -e 'tell application "Cursor" to activate' \
    -e 'delay 0.2' \
    -e 'tell application "System Events" to key code 123 using {control down, shift down, command down}'

  cd "$worktree_path"
  claude
}
