# Create a GitHub issue (or develop an existing one) and set up a worktree
# Usage: ghwt [-c] [-b <branch>] [-i <number>] "Issue title"
# Automatically detects forks and routes issues to the upstream repo.
ghwt() {
  local base_branch="" issue_number="" branch_name=""

  # Parse flags
  while [[ "$1" == -* ]]; do
    case "$1" in
      -c|--current)
        base_branch=$(git branch --show-current)
        shift
        ;;
      -b|--branch)
        branch_name="$2"
        shift 2
        ;;
      -i|--issue)
        issue_number="$2"
        shift 2
        ;;
      -h|--help)
        echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
        echo "  -b, --branch B  Use existing branch instead of creating one"
        echo "  -c, --current   Branch from current branch instead of main"
        echo "  -i, --issue N   Develop an existing issue instead of creating one"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Automatically detects forks and creates issues on the upstream repo."
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
        return 1
        ;;
    esac
  done

  # Detect if this repo is a fork
  local is_fork=false upstream_repo="" fork_repo=""
  upstream_repo=$(gh repo view --json parent -q '.parent.owner.login + "/" + .parent.name' 2>/dev/null)
  if [[ -n "$upstream_repo" && "$upstream_repo" != "null/null" && "$upstream_repo" != "/" ]]; then
    is_fork=true
    fork_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
    echo "Detected fork of $upstream_repo"
  fi

  # If no existing issue, create one from title
  if [[ -z "$issue_number" ]]; then
    local title="$1"
    if [[ -z "$title" ]]; then
      echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
      return 1
    fi

    local issue_url
    if $is_fork; then
      issue_url=$(gh issue create -R "$upstream_repo" --title "$title" --body "" 2>&1)
    else
      issue_url=$(gh issue create --title "$title" --body "" 2>&1)
    fi
    if [[ $? -ne 0 ]]; then
      echo "Failed to create issue: $issue_url"
      return 1
    fi

    issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
    echo "Created issue #$issue_number: $issue_url"
  else
    echo "Developing existing issue #$issue_number"
  fi

  if [[ -z "$branch_name" ]]; then
    # Use gh issue develop to create a branch
    local develop_output base_arg=""
    [[ -n "$base_branch" ]] && base_arg="--base $base_branch"
    if $is_fork; then
      develop_output=$(gh issue develop "$issue_number" -R "$upstream_repo" --branch-repo "$fork_repo" $base_arg 2>&1)
    else
      develop_output=$(gh issue develop "$issue_number" $base_arg 2>&1)
    fi
    if [[ $? -ne 0 ]]; then
      echo "Failed to create branch: $develop_output"
      return 1
    fi

    # Extract branch name from the URL line (format: "github.com/owner/repo/tree/branch-name")
    branch_name=$(echo "$develop_output" | grep '/tree/' | head -1 | grep -oE '[^/]+$')
    echo "Created branch: $branch_name"
  else
    echo "Using existing branch: $branch_name"
  fi

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
  _worktree_setup "$worktree_path"

  # Open Cursor and tile left
  cursor --new-window "$worktree_path"

  # Split-tile: show PICK ME banner and tile Cursor left
  splt

  # Start claude in the worktree
  local issue_view_cmd="gh issue view ${issue_number}"
  $is_fork && issue_view_cmd="gh issue view ${issue_number} -R ${upstream_repo}"
  cd "$worktree_path" && claude --permission-mode plan "Implement GitHub issue #${issue_number}. Run ${issue_view_cmd} for details."
}

