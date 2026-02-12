# Create a GitHub issue (or develop an existing one) and set up a worktree
# Usage: ghwt [-c] [-i <number>] "Issue title"
ghwt() {
  local base_branch="" issue_number=""

  # Parse flags
  while [[ "$1" == -* ]]; do
    case "$1" in
      -c|--current)
        base_branch=$(git branch --show-current)
        shift
        ;;
      -i|--issue)
        issue_number="$2"
        shift 2
        ;;
      -h|--help)
        echo "Usage: ghwt [-c] [-i <number>] \"Issue title\""
        echo "  -c, --current   Branch from current branch instead of main"
        echo "  -i, --issue N   Develop an existing issue instead of creating one"
        echo "  -h, --help      Show this help"
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ghwt [-c] [-i <number>] \"Issue title\""
        return 1
        ;;
    esac
  done

  # If no existing issue, create one from title
  if [[ -z "$issue_number" ]]; then
    local title="$1"
    if [[ -z "$title" ]]; then
      echo "Usage: ghwt [-c] [-i <number>] \"Issue title\""
      return 1
    fi

    local issue_url
    issue_url=$(gh issue create --title "$title" --body "" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "Failed to create issue: $issue_url"
      return 1
    fi

    issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
    echo "Created issue #$issue_number: $issue_url"
  else
    echo "Developing existing issue #$issue_number"
  fi

  # Use gh issue develop to create a branch
  local develop_output base_arg=""
  [[ -n "$base_branch" ]] && base_arg="--base $base_branch"
  develop_output=$(gh issue develop "$issue_number" $base_arg 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Failed to create branch: $develop_output"
    return 1
  fi

  # Extract branch name from the URL line (format: "github.com/owner/repo/tree/branch-name")
  local branch_name
  branch_name=$(echo "$develop_output" | grep '/tree/' | head -1 | grep -oE '[^/]+$')
  echo "Created branch: $branch_name"

  # Fetch the new branch
  git fetch origin "$branch_name"

  # Ensure worktrees directory exists
  mkdir -p ~/.claude/worktrees

  # Resolve main repo root (works from both main checkout and linked worktrees)
  local repo_root
  repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  local repo_name
  repo_name=$(basename "$repo_root")
  local worktree_path="$HOME/.claude/worktrees/${repo_name}-${issue_number}"

  # Create the worktree
  git worktree add "$worktree_path" "$branch_name"

  echo "Worktree created at: $worktree_path"

  # Run worktree setup
  (_worktree_setup "$worktree_path" "$repo_root")

  # Open Cursor and tile left
  open -a "Cursor" "$worktree_path"

  # Open new Ghostty window in worktree and start claude
  cd "$worktree_path" && ght claude
}

