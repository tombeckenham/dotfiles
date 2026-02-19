# Create a worktree for an existing branch (without GitHub issue)
# Usage: wt <branch-name>
wt() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: wt <branch-name>"
    echo "  Create a worktree for an existing branch"
    return 0
  fi

  local branch_name="$1"

  # Check if branch exists locally
  if ! git show-ref --verify --quiet refs/heads/"$branch_name"; then
    # Branch doesn't exist locally, check remote
    if ! git show-ref --verify --quiet refs/remotes/origin/"$branch_name"; then
      echo "Error: Branch '$branch_name' does not exist locally or remotely"
      return 1
    fi

    # Fetch the branch from remote
    echo "Fetching branch '$branch_name' from remote..."
    git fetch origin "$branch_name"
    if [[ $? -ne 0 ]]; then
      echo "Failed to fetch branch '$branch_name' from remote"
      return 1
    fi
  fi

  # Ensure worktrees directory exists
  mkdir -p ~/.claude/worktrees

  # Get repo name for worktree folder
  local repo_name
  repo_name=$(basename "$(git rev-parse --show-toplevel)")

  # Sanitize branch name for filesystem (replace / and other invalid chars with -)
  local sanitized_branch_name
  sanitized_branch_name=$(echo "$branch_name" | sed 's/[\/<>:"|?*]/-/g')

  local worktree_path="$HOME/.claude/worktrees/${repo_name}-${sanitized_branch_name}"

  # Check if worktree already exists
  if [[ -d "$worktree_path" ]]; then
    echo "Worktree already exists at: $worktree_path"
    echo "Opening existing worktree..."
  else
    # Create the worktree
    git worktree add "$worktree_path" "$branch_name"
    if [[ $? -ne 0 ]]; then
      echo "Failed to create worktree"
      return 1
    fi
    echo "Worktree created at: $worktree_path"

    # Run worktree setup
    _worktree_setup "$worktree_path"
  fi

  # Open Cursor and arrange Left & Right (Cursor left, Ghostty right)
  open -a "Cursor" "$worktree_path"
  sleep 0.8
  osascript -e 'tell application "Cursor" to activate' \
    -e 'delay 0.2' \
    -e 'tell application "System Events" to key code 123 using {control down, shift down, command down}'

  # cd and start claude
  cd "$worktree_path"
  claude
}
